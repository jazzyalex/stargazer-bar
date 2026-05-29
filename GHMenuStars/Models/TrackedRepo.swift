import Foundation

struct TrackedRepo: Codable, Identifiable, Equatable {
    var id: UUID
    var owner: String
    var name: String
    var displayName: String
    var source: RepoSource
    var lastStars: Int?
    var lastDownloads: Int?
    var lastCheckedAt: Date?
    var lastSuccessfulCheckAt: Date?
    var lastNotifiedStars: Int?
    var lastNotifiedDownloads: Int?
    var lastStarsDelta: Int?
    var lastDownloadsDelta: Int?
    var etagRepo: String?
    var etagReleases: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case displayName
        case source
        case lastStars
        case lastDownloads
        case lastCheckedAt
        case lastSuccessfulCheckAt
        case lastNotifiedStars
        case lastNotifiedDownloads
        case lastStarsDelta
        case lastDownloadsDelta
        case etagRepo
        case etagReleases
    }

    init(
        id: UUID = UUID(),
        owner: String,
        name: String,
        displayName: String? = nil,
        source: RepoSource,
        lastStars: Int? = nil,
        lastDownloads: Int? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil,
        lastNotifiedStars: Int? = nil,
        lastNotifiedDownloads: Int? = nil,
        lastStarsDelta: Int? = nil,
        lastDownloadsDelta: Int? = nil,
        etagRepo: String? = nil,
        etagReleases: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.displayName = displayName ?? "\(owner)/\(name)"
        self.source = source
        self.lastStars = lastStars
        self.lastDownloads = lastDownloads
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastNotifiedStars = lastNotifiedStars
        self.lastNotifiedDownloads = lastNotifiedDownloads
        self.lastStarsDelta = lastStarsDelta
        self.lastDownloadsDelta = lastDownloadsDelta
        self.etagRepo = etagRepo
        self.etagReleases = etagReleases
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
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastSuccessfulCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulCheckAt)
        lastNotifiedStars = try container.decodeIfPresent(Int.self, forKey: .lastNotifiedStars)
        lastNotifiedDownloads = try container.decodeIfPresent(Int.self, forKey: .lastNotifiedDownloads)
        lastStarsDelta = try container.decodeIfPresent(Int.self, forKey: .lastStarsDelta)
        lastDownloadsDelta = try container.decodeIfPresent(Int.self, forKey: .lastDownloadsDelta)
        etagRepo = try container.decodeIfPresent(String.self, forKey: .etagRepo)
        etagReleases = try container.decodeIfPresent(String.self, forKey: .etagReleases)
    }
}
