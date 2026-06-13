import Foundation

struct RepoTrendPoint: Codable, Equatable {
    var date: Date
    var stars: Int
    var forks: Int
}

enum RepoTrendBuilder {
    static func points(
        stars: Int,
        forks: Int,
        starDates: [Date],
        forkDates: [Date],
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [RepoTrendPoint] {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -365, to: end) ?? end.addingTimeInterval(-365 * 86_400)
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
        trendPoints: [RepoTrendPoint] = []
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
    }

}
