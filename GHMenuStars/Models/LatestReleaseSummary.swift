import Foundation

struct LatestReleaseSummary: Codable, Equatable {
    struct AssetCount: Codable, Equatable {
        var label: String
        var count: Int
    }

    var tag: String
    var name: String?
    var publishedAt: Date
    var isPrerelease: Bool
    var downloads: Int
    var totalDownloads: Int
    var assets: [AssetCount]
}
