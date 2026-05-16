enum ReleaseDownloadAggregator {
    static func totalDownloads(from releases: [GitHubRelease]) -> Int {
        releases.reduce(0) { releaseTotal, release in
            releaseTotal + release.assets.reduce(0) { $0 + $1.downloadCount }
        }
    }
}

