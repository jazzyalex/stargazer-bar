import Foundation

enum ReleaseDynamics {
    static let releaseFreshnessWindow: TimeInterval = 60 * 60 * 24 * 14

    static func isFresh(publishedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(publishedAt) <= releaseFreshnessWindow
    }

    static func dailyRate(downloads: Int, publishedAt: Date, now: Date = Date()) -> Int {
        let days = max(1, now.timeIntervalSince(publishedAt) / (60 * 60 * 24))
        return Int((Double(downloads) / days).rounded())
    }

    static func sharePercent(downloads: Int, totalDownloads: Int) -> Int? {
        guard totalDownloads > 0 else { return nil }
        return Int((Double(downloads) / Double(totalDownloads) * 100).rounded())
    }

    static func starsSinceRelease(trendPoints: [RepoTrendPoint], currentStars: Int, publishedAt: Date) -> Int? {
        let baseline = trendPoints
            .filter { $0.date <= publishedAt }
            .max(by: { $0.date < $1.date })
        guard let baseline else { return nil }
        return max(0, currentStars - baseline.stars)
    }
}
