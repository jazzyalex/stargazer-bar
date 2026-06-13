import Foundation

struct RepoSnapshot: Equatable {
    var stars: Int
    var releaseDownloads: Int
    var forks: Int
    var checkedAt: Date
    var repoETag: String?
    var releasesETag: String?
    var trendPoints: [RepoTrendPoint]? = nil
    var trendRange: RepoTrendRange? = nil
}
