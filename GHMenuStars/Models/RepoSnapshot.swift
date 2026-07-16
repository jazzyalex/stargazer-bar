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
    var maintainerRadar: RepoMaintainerRadar? = nil
    var latestRelease: LatestReleaseSummary? = nil
    var recentReleases: RecentReleasesSummary? = nil
    /// Authoritative, read from the repo response body. Declared last so the
    /// memberwise init stays compatible with existing call sites.
    var isPrivate: Bool = false
    var commitActivity: [CommitDayCount]? = nil
}
