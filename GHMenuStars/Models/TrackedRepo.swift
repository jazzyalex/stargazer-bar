import Foundation

struct RepoTrendPoint: Codable, Equatable {
    var date: Date
    var stars: Int
    var forks: Int
}

/// One day's commit count, across every branch. Deliberately not a
/// `RepoTrendPoint`: that models a cumulative all-time curve pinned to a known
/// total, whereas this is a sliding window with no total to pin to, whose oldest
/// points fall off as it slides.
struct CommitDayCount: Codable, Equatable, Identifiable {
    var date: Date
    var count: Int
    var id: Date { date }
}

enum CommitActivityBuilder {
    /// Buckets commit dates into one entry per day, including empty days — a
    /// chart with gaps silently omitted reads as "no data" rather than "no work".
    static func buckets(
        from dates: [Date],
        since: Date,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [CommitDayCount] {
        let start = calendar.startOfDay(for: since)
        let end = calendar.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for date in dates where date >= since {
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }
        var result: [CommitDayCount] = []
        var day = start
        while day <= end {
            result.append(CommitDayCount(date: day, count: counts[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func total(_ buckets: [CommitDayCount], since: Date) -> Int {
        buckets.filter { $0.date >= since }.reduce(0) { $0 + $1.count }
    }
}

struct RepoWorkflowFailure: Codable, Equatable {
    var name: String
    var url: String
    /// When the failing run happened. A months-old failure and a fresh one are
    /// not the same news.
    var failedAt: Date?
}

struct RepoMaintainerRadar: Codable, Equatable {
    var openPullRequests: Int?
    var newPullRequests: Int?
    var newIssues: Int?
    var unansweredIssues: Int?
    var recentCommits: Int?
    var activityWindow: MaintainerRadarActivityWindow?
    var activityAnchoredSince: Date? = nil
    var latestFailedWorkflow: RepoWorkflowFailure?
    var workflowChecked: Bool
    var checkedAt: Date

    var hasData: Bool {
        openPullRequests != nil ||
            newPullRequests != nil ||
            newIssues != nil ||
            unansweredIssues != nil ||
            recentCommits != nil ||
            workflowChecked
    }

    var attentionCount: Int {
        (newPullRequests ?? 0) +
            (newIssues ?? 0) +
            (unansweredIssues ?? 0) +
            (latestFailedWorkflow == nil ? 0 : 1)
    }
}

struct RepoTrendAxisTick: Equatable {
    var date: Date
    var label: String
}

enum StarAskPromptStatus: String, Codable, Equatable {
    case notShown
    case later
    case starred
    case dismissed

    var canPrompt: Bool {
        switch self {
        case .notShown, .later: return true
        case .starred, .dismissed: return false
        }
    }
}

enum RepoTrendAxisTickBuilder {
    static func ticks(
        start: Date,
        end: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        maxTicks: Int = 5
    ) -> [RepoTrendAxisTick] {
        guard end > start, maxTicks > 0 else { return [] }
        let days = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let rawTicks: [RepoTrendAxisTick]

        if days > 730 {
            rawTicks = componentTicks(
                start: start,
                end: end,
                component: .year,
                step: 1,
                calendar: calendar,
                formatter: yearFormatter
            )
        } else if days > 62 {
            rawTicks = componentTicks(
                start: start,
                end: end,
                component: .month,
                step: days > 370 ? 3 : (days > 180 ? 2 : 1),
                calendar: calendar,
                formatter: monthFormatter
            )
        } else {
            rawTicks = dayTicks(
                start: start,
                end: end,
                step: days > 21 ? 7 : (days > 10 ? 3 : 1),
                calendar: calendar
            )
        }

        return thin(rawTicks, maxCount: maxTicks)
    }

    private static func componentTicks(
        start: Date,
        end: Date,
        component: Calendar.Component,
        step: Int,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> [RepoTrendAxisTick] {
        var components = calendar.dateComponents([.year, .month], from: start)
        switch component {
        case .year:
            components.year = (components.year ?? 0) + 1
            components.month = 1
            components.day = 1
        case .month:
            components.month = (components.month ?? 0) + 1
            components.day = 1
        default:
            return []
        }

        guard var date = calendar.date(from: components) else { return [] }
        var ticks: [RepoTrendAxisTick] = []
        while date < end {
            ticks.append(RepoTrendAxisTick(date: date, label: formatter.string(from: date)))
            guard let next = calendar.date(byAdding: component, value: step, to: date) else { break }
            date = next
        }
        return ticks
    }

    private static func dayTicks(start: Date, end: Date, step: Int, calendar: Calendar) -> [RepoTrendAxisTick] {
        guard var date = calendar.date(byAdding: .day, value: step, to: calendar.startOfDay(for: start)) else {
            return []
        }
        var ticks: [RepoTrendAxisTick] = []
        while date < end {
            ticks.append(RepoTrendAxisTick(date: date, label: dayFormatter.string(from: date)))
            guard let next = calendar.date(byAdding: .day, value: step, to: date) else { break }
            date = next
        }
        return ticks
    }

    private static func thin(_ ticks: [RepoTrendAxisTick], maxCount: Int) -> [RepoTrendAxisTick] {
        guard ticks.count > maxCount else { return ticks }
        let stride = Int(ceil(Double(ticks.count) / Double(maxCount)))
        return ticks.enumerated().compactMap { index, tick in
            index % stride == 0 ? tick : nil
        }
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}

enum RepoTrendBuilder {
    static func points(
        stars: Int,
        forks: Int,
        starDates: [Date],
        forkDates: [Date],
        range: RepoTrendRange = .twelveMonths,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [RepoTrendPoint] {
        let end = calendar.startOfDay(for: now)
        let firstEventDate = (starDates + forkDates).min().map { calendar.startOfDay(for: $0) }
        let start = range.startDate(now: end, calendar: calendar)
            ?? firstEventDate
            ?? end
        let recentStarDays = countsByDay(starDates, from: start, through: now, calendar: calendar)
        let recentForkDays = countsByDay(forkDates, from: start, through: now, calendar: calendar)
        let baselineStars = max(0, stars - recentStarDays.values.reduce(0, +))
        let baselineForks = max(0, forks - recentForkDays.values.reduce(0, +))

        var points: [RepoTrendPoint] = []
        var runningStars = baselineStars
        var runningForks = baselineForks
        var day = start

        while day <= end {
            runningStars += recentStarDays[day] ?? 0
            runningForks += recentForkDays[day] ?? 0
            points.append(RepoTrendPoint(date: day, stars: runningStars, forks: runningForks))
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        if var last = points.last {
            last.stars = stars
            last.forks = forks
            points[points.count - 1] = last
        }

        return points
    }

    /// Extends an existing all-time curve with only the events observed since
    /// the last check, instead of rebuilding from the full history. The historical
    /// prefix is preserved verbatim; new events bump the current day and/or append
    /// new daily points, and the final point is re-pinned to the true totals.
    static func extend(
        existing: [RepoTrendPoint],
        newStarDates: [Date],
        newForkDates: [Date],
        totalStars: Int,
        totalForks: Int,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [RepoTrendPoint] {
        guard let last = existing.last else {
            return points(
                stars: totalStars,
                forks: totalForks,
                starDates: newStarDates,
                forkDates: newForkDates,
                range: .all,
                now: now,
                calendar: calendar
            )
        }

        let end = calendar.startOfDay(for: now)
        let starByDay = countsByDay(newStarDates, from: last.date, through: now, calendar: calendar)
        let forkByDay = countsByDay(newForkDates, from: last.date, through: now, calendar: calendar)

        var points = existing
        // Events landing on the current final day bump that point in place.
        var running = last
        running.stars += starByDay[last.date] ?? 0
        running.forks += forkByDay[last.date] ?? 0
        points[points.count - 1] = running

        var day = calendar.date(byAdding: .day, value: 1, to: last.date) ?? end
        while day <= end {
            running = RepoTrendPoint(
                date: day,
                stars: running.stars + (starByDay[day] ?? 0),
                forks: running.forks + (forkByDay[day] ?? 0)
            )
            points.append(running)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        if var tail = points.last {
            tail.stars = totalStars
            tail.forks = totalForks
            points[points.count - 1] = tail
        }
        return points
    }

    private static func countsByDay(
        _ dates: [Date],
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> [Date: Int] {
        dates.reduce(into: [:]) { counts, date in
            guard date >= start, date <= end else { return }
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }
    }
}

/// Why the last refresh failed, when it did. Persisted so the UI can say
/// something true instead of showing a stale number under a fresh timestamp.
enum RepoRefreshFailure: String, Codable, Equatable {
    case notFoundOrNoAccess
    case privateTokenRejected
    case rateLimited
    case server
    case offline

    var userMessage: String {
        switch self {
        case .notFoundOrNoAccess:
            return "Can't see this repository — it may have been deleted, renamed, or made private."
        case .privateTokenRejected:
            return "Private repo token was revoked or expired."
        case .rateLimited:
            return "GitHub rate limit reached."
        case .server:
            return "GitHub returned an error."
        case .offline:
            return "Couldn't reach GitHub."
        }
    }
}

struct TrackedRepo: Codable, Identifiable, Equatable {
    var id: UUID
    var owner: String
    var name: String
    var displayName: String
    var source: RepoSource
    var isPrivate: Bool
    var lastStars: Int?
    var lastDownloads: Int?
    var lastForks: Int?
    var lastCheckedAt: Date?
    var lastSuccessfulCheckAt: Date?
    var lastNotifiedStars: Int?
    var lastNotifiedDownloads: Int?
    var lastStarsDelta: Int?
    var lastDownloadsDelta: Int?
    var lastForksDelta: Int?
    var etagRepo: String?
    var etagReleases: String?
    var starSound: StarSound
    var isMuted: Bool
    var trendPoints: [RepoTrendPoint]
    var trendRange: RepoTrendRange?
    var maintainerRadar: RepoMaintainerRadar?
    var latestRelease: LatestReleaseSummary?
    var recentReleases: RecentReleasesSummary?
    var starAskPromptStatus: StarAskPromptStatus
    var lastStarAskPromptedAt: Date?
    /// Non-nil when the most recent refresh failed. Cleared on success.
    var lastRefreshFailure: RepoRefreshFailure?
    /// When a refresh was last *attempted*, successful or not — distinct from
    /// lastCheckedAt, which must only mean "we got data".
    var lastAttemptedCheckAt: Date?
    /// Daily commit counts across all branches, rebuilt wholesale each poll.
    var commitActivity: [CommitDayCount]?

    private enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case displayName
        case source
        case isPrivate
        case lastStars
        case lastDownloads
        case lastForks
        case lastCheckedAt
        case lastSuccessfulCheckAt
        case lastNotifiedStars
        case lastNotifiedDownloads
        case lastStarsDelta
        case lastDownloadsDelta
        case lastForksDelta
        case etagRepo
        case etagReleases
        case starSound
        case isMuted
        case trendPoints
        case trendRange
        case maintainerRadar
        case latestRelease
        case recentReleases
        case starAskPromptStatus
        case lastStarAskPromptedAt
        case lastRefreshFailure
        case lastAttemptedCheckAt
        case commitActivity
    }

    init(
        id: UUID = UUID(),
        owner: String,
        name: String,
        displayName: String? = nil,
        source: RepoSource,
        isPrivate: Bool = false,
        lastStars: Int? = nil,
        lastDownloads: Int? = nil,
        lastForks: Int? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil,
        lastNotifiedStars: Int? = nil,
        lastNotifiedDownloads: Int? = nil,
        lastStarsDelta: Int? = nil,
        lastDownloadsDelta: Int? = nil,
        lastForksDelta: Int? = nil,
        etagRepo: String? = nil,
        etagReleases: String? = nil,
        starSound: StarSound = .glass,
        isMuted: Bool = false,
        trendPoints: [RepoTrendPoint] = [],
        trendRange: RepoTrendRange? = nil,
        maintainerRadar: RepoMaintainerRadar? = nil,
        latestRelease: LatestReleaseSummary? = nil,
        recentReleases: RecentReleasesSummary? = nil,
        starAskPromptStatus: StarAskPromptStatus = .notShown,
        lastStarAskPromptedAt: Date? = nil,
        lastRefreshFailure: RepoRefreshFailure? = nil,
        lastAttemptedCheckAt: Date? = nil,
        commitActivity: [CommitDayCount]? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.displayName = displayName ?? "\(owner)/\(name)"
        self.source = source
        self.isPrivate = isPrivate
        self.lastStars = lastStars
        self.lastDownloads = lastDownloads
        self.lastForks = lastForks
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastNotifiedStars = lastNotifiedStars
        self.lastNotifiedDownloads = lastNotifiedDownloads
        self.lastStarsDelta = lastStarsDelta
        self.lastDownloadsDelta = lastDownloadsDelta
        self.lastForksDelta = lastForksDelta
        self.etagRepo = etagRepo
        self.etagReleases = etagReleases
        self.starSound = starSound
        self.isMuted = isMuted
        self.trendPoints = trendPoints
        self.trendRange = trendRange
        self.maintainerRadar = maintainerRadar
        self.latestRelease = latestRelease
        self.recentReleases = recentReleases
        self.starAskPromptStatus = starAskPromptStatus
        self.lastStarAskPromptedAt = lastStarAskPromptedAt
        self.lastRefreshFailure = lastRefreshFailure
        self.lastAttemptedCheckAt = lastAttemptedCheckAt
        self.commitActivity = commitActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        source = try container.decode(RepoSource.self, forKey: .source)
        // Repos stored before private support predate this field; public is correct.
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        lastStars = try container.decodeIfPresent(Int.self, forKey: .lastStars)
        lastDownloads = try container.decodeIfPresent(Int.self, forKey: .lastDownloads)
        lastForks = try container.decodeIfPresent(Int.self, forKey: .lastForks)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastSuccessfulCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulCheckAt)
        lastNotifiedStars = try container.decodeIfPresent(Int.self, forKey: .lastNotifiedStars)
        lastNotifiedDownloads = try container.decodeIfPresent(Int.self, forKey: .lastNotifiedDownloads)
        lastStarsDelta = try container.decodeIfPresent(Int.self, forKey: .lastStarsDelta)
        lastDownloadsDelta = try container.decodeIfPresent(Int.self, forKey: .lastDownloadsDelta)
        lastForksDelta = try container.decodeIfPresent(Int.self, forKey: .lastForksDelta)
        etagRepo = try container.decodeIfPresent(String.self, forKey: .etagRepo)
        etagReleases = try container.decodeIfPresent(String.self, forKey: .etagReleases)
        starSound = try container.decodeIfPresent(StarSound.self, forKey: .starSound) ?? .glass
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        trendPoints = try container.decodeIfPresent([RepoTrendPoint].self, forKey: .trendPoints) ?? []
        trendRange = try container.decodeIfPresent(RepoTrendRange.self, forKey: .trendRange)
        maintainerRadar = try container.decodeIfPresent(RepoMaintainerRadar.self, forKey: .maintainerRadar)
        latestRelease = try container.decodeIfPresent(LatestReleaseSummary.self, forKey: .latestRelease)
        recentReleases = try container.decodeIfPresent(RecentReleasesSummary.self, forKey: .recentReleases)
        starAskPromptStatus = try container.decodeIfPresent(StarAskPromptStatus.self, forKey: .starAskPromptStatus) ?? .notShown
        lastStarAskPromptedAt = try container.decodeIfPresent(Date.self, forKey: .lastStarAskPromptedAt)
        lastRefreshFailure = try container.decodeIfPresent(RepoRefreshFailure.self, forKey: .lastRefreshFailure)
        lastAttemptedCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedCheckAt)
        commitActivity = try container.decodeIfPresent([CommitDayCount].self, forKey: .commitActivity)
    }

}
