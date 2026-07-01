import Foundation

enum ReleaseDynamics {
    static let releaseFreshnessWindow: TimeInterval = 60 * 60 * 24 * 14
    static let recentWindowDays = 30

    static func value(in points: [RepoTrendPoint], at date: Date, keyPath: KeyPath<RepoTrendPoint, Int>) -> Int? {
        points.filter { $0.date <= date }.max(by: { $0.date < $1.date })?[keyPath: keyPath]
    }

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
        guard let baseline = value(in: trendPoints, at: publishedAt, keyPath: \.stars) else { return nil }
        return max(0, currentStars - baseline)
    }
}
