import Foundation

struct RepoTrendPoint: Codable, Equatable {
    var date: Date
    var stars: Int
    var forks: Int
}

struct RepoWorkflowFailure: Codable, Equatable {
    var name: String
    var url: String
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

struct TrackedRepo: Codable, Identifiable, Equatable {
    var id: UUID
    var owner: String
    var name: String
    var displayName: String
    var source: RepoSource
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
    var trendPoints: [RepoTrendPoint]
    var trendRange: RepoTrendRange?
    var maintainerRadar: RepoMaintainerRadar?
    var latestRelease: LatestReleaseSummary?
    var recentReleases: RecentReleasesSummary?
    var starAskPromptStatus: StarAskPromptStatus
    var lastStarAskPromptedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case displayName
        case source
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
        case trendPoints
        case trendRange
        case maintainerRadar
        case latestRelease
        case recentReleases
        case starAskPromptStatus
        case lastStarAskPromptedAt
    }

    init(
        id: UUID = UUID(),
        owner: String,
        name: String,
        displayName: String? = nil,
        source: RepoSource,
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
        trendPoints: [RepoTrendPoint] = [],
        trendRange: RepoTrendRange? = nil,
        maintainerRadar: RepoMaintainerRadar? = nil,
        latestRelease: LatestReleaseSummary? = nil,
        recentReleases: RecentReleasesSummary? = nil,
        starAskPromptStatus: StarAskPromptStatus = .notShown,
        lastStarAskPromptedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.displayName = displayName ?? "\(owner)/\(name)"
        self.source = source
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
        self.trendPoints = trendPoints
        self.trendRange = trendRange
        self.maintainerRadar = maintainerRadar
        self.latestRelease = latestRelease
        self.recentReleases = recentReleases
        self.starAskPromptStatus = starAskPromptStatus
        self.lastStarAskPromptedAt = lastStarAskPromptedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        source = try container.decode(RepoSource.self, forKey: .source)
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
        trendPoints = try container.decodeIfPresent([RepoTrendPoint].self, forKey: .trendPoints) ?? []
        trendRange = try container.decodeIfPresent(RepoTrendRange.self, forKey: .trendRange)
        maintainerRadar = try container.decodeIfPresent(RepoMaintainerRadar.self, forKey: .maintainerRadar)
        latestRelease = try container.decodeIfPresent(LatestReleaseSummary.self, forKey: .latestRelease)
        recentReleases = try container.decodeIfPresent(RecentReleasesSummary.self, forKey: .recentReleases)
        starAskPromptStatus = try container.decodeIfPresent(StarAskPromptStatus.self, forKey: .starAskPromptStatus) ?? .notShown
        lastStarAskPromptedAt = try container.decodeIfPresent(Date.self, forKey: .lastStarAskPromptedAt)
    }

}
