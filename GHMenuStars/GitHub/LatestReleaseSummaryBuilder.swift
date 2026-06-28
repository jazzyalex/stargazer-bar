import Foundation

enum LatestReleaseSummaryBuilder {
    static func summary(from releases: [GitHubRelease], totalDownloads: Int) -> LatestReleaseSummary? {
        let published = releases.compactMap { release -> (GitHubRelease, Date)? in
            guard !release.draft, let date = release.publishedAt else { return nil }
            return (release, date)
        }
        guard let (latest, publishedAt) = published.max(by: { $0.1 < $1.1 }) else { return nil }

        let downloads = latest.assets.reduce(0) { $0 + $1.downloadCount }
        let labels = shortLabels(for: latest.assets.map(\.name))
        let assets = zip(labels, latest.assets.map(\.downloadCount))
            .map { LatestReleaseSummary.AssetCount(label: $0.0, count: $0.1) }
            .sorted { $0.count > $1.count }
            .prefix(2)

        return LatestReleaseSummary(
            tag: latest.tagName,
            name: latest.name,
            publishedAt: publishedAt,
            isPrerelease: latest.prerelease,
            downloads: downloads,
            totalDownloads: totalDownloads,
            assets: Array(assets)
        )
    }

    static func shortLabels(for names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        let prefix = commonPrefix(of: names)
        return names.map { name in
            var label = String(name.dropFirst(prefix.count))
            while let first = label.first, first == "-" || first == "." || first == "_" {
                label.removeFirst()
            }
            if label.isEmpty { label = name }
            if label.count > 16 {
                let parts = label.split(separator: "-").suffix(2).joined(separator: "-")
                label = parts.isEmpty ? String(label.suffix(16)) : parts
            }
            return label
        }
    }

    private static func commonPrefix(of names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.0 == $0.1 }.map(\.0))
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
