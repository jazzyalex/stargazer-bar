import Foundation

struct RepoSnapshot: Equatable {
    var stars: Int
    var releaseDownloads: Int
    var checkedAt: Date
    var repoETag: String?
    var releasesETag: String?
}

