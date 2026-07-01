import Foundation

enum RecentReleasesSummaryBuilder {
    static func summary(from releases: [GitHubRelease], totalDownloads: Int, now: Date = Date()) -> RecentReleasesSummary? {
        let published = releases.compactMap { release -> (GitHubRelease, Date)? in
            guard !release.draft, let date = release.publishedAt else { return nil }
            return (release, date)
        }
        guard !published.isEmpty else { return nil }

        let windowStart = now.addingTimeInterval(-Double(ReleaseDynamics.recentWindowDays) * 24 * 60 * 60)
        let recent = published.filter { $0.1 >= windowStart }
        let downloads = recent.reduce(0) { total, entry in
            total + entry.0.assets.reduce(0) { $0 + $1.downloadCount }
        }
        return RecentReleasesSummary(releaseCount: recent.count, downloads: downloads, totalDownloads: totalDownloads)
    }
}
