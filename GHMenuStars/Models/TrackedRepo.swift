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
    var etagRepo: String?
    var etagReleases: String?

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
        self.etagRepo = etagRepo
        self.etagReleases = etagReleases
    }
}

