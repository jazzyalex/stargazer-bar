import Foundation

/// A day whose star growth stood out sharply from the repo's own recent pace.
struct AnomalyDay: Equatable {
    var date: Date
    /// Stars added that day (the daily increment).
    var gain: Int
    /// `gain` divided by the robust baseline for that day — how many times "normal" it was.
    var multipleOfNormal: Double
}

/// Finds abnormally large single-day star gains in a repo's stored daily trend
/// history. Pure and offline: it reads only `RepoTrendPoint` data the app already
/// has, so it adds no network activity and touches no persisted state.
enum TrendAnomalyDetector {
    /// Trailing daily increments used to characterise "normal" for a given day.
    static let baselineWindow = 30
    /// Minimum increments needed before we're willing to call anything anomalous.
    static let minIncrements = 7
    /// Robust z-score cutoff (median + z · scaledMAD).
    static let zThreshold = 3.5
    /// Gains below this are treated as noise regardless of the baseline.
    static let absoluteFloor = 3
    /// MAD → σ conversion factor for a normal distribution.
    private static let madScale = 1.4826

    /// Consecutive daily star increments, oldest first. Negative jumps (GitHub
    /// count corrections) are clamped to zero. The first stored point carries a
    /// collapsed baseline, so it has no increment and is skipped.
    static func dailyGains(_ points: [RepoTrendPoint]) -> [(date: Date, gain: Int)] {
        let sorted = points.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return [] }
        return (1..<sorted.count).map { index in
            (sorted[index].date, max(0, sorted[index].stars - sorted[index - 1].stars))
        }
    }

    static func anomalies(in points: [RepoTrendPoint]) -> [AnomalyDay] {
        let gains = dailyGains(points)
        guard gains.count >= minIncrements else { return [] }

        var result: [AnomalyDay] = []
        for (index, entry) in gains.enumerated() {
            let windowStart = max(0, index - baselineWindow)
            let window = gains[windowStart..<index].map { Double($0.gain) }
            guard window.count >= minIncrements else { continue }
            guard entry.gain >= absoluteFloor else { continue }

            let med = median(window)
            let mad = median(window.map { abs($0 - med) })
            let gain = Double(entry.gain)

            let isAnomaly: Bool
            if mad == 0 {
                // A perfectly flat window has no spread to score against, so any
                // jump clearly above the median (and the floor) is the anomaly.
                isAnomaly = gain > med + Double(absoluteFloor)
            } else {
                isAnomaly = (gain - med) / (mad * madScale) >= zThreshold
            }

            if isAnomaly {
                result.append(AnomalyDay(date: entry.date, gain: entry.gain, multipleOfNormal: gain / max(1, med)))
            }
        }
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Standout-moment summaries derived from the same daily trend history. Used for
/// the "Highlights" rows under the trend chart.
enum TrendAnomalyStats {
    struct PeakWeek: Equatable {
        var start: Date
        var end: Date
        var gain: Int
    }

    /// The single biggest star day across stored history, or `nil` when history
    /// is too short to be meaningful.
    static func bestDay(in points: [RepoTrendPoint]) -> AnomalyDay? {
        let gains = TrendAnomalyDetector.dailyGains(points)
        guard gains.count >= TrendAnomalyDetector.minIncrements else { return nil }
        guard let best = gains.max(by: { $0.gain < $1.gain }), best.gain > 0 else { return nil }
        return AnomalyDay(date: best.date, gain: best.gain, multipleOfNormal: 0)
    }

    /// The rolling 7-day window with the largest total star gain. Because the
    /// series is cumulative and monotonically increasing, the earliest point
    /// inside a window carries the smallest count, so a forward two-pointer scan
    /// yields the maximum gain per window end in one pass.
    static func peakWeek(in points: [RepoTrendPoint]) -> PeakWeek? {
        let sorted = points.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        guard TrendAnomalyDetector.dailyGains(sorted).count >= TrendAnomalyDetector.minIncrements else { return nil }

        let weekSpan = 7.0 * 86_400
        var best: PeakWeek?
        var low = 0
        for high in 1..<sorted.count {
            while sorted[high].date.timeIntervalSince(sorted[low].date) > weekSpan {
                low += 1
            }
            let gain = sorted[high].stars - sorted[low].stars
            if gain > (best?.gain ?? 0) {
                best = PeakWeek(start: sorted[low].date, end: sorted[high].date, gain: gain)
            }
        }
        guard let best, best.gain > 0 else { return nil }
        return best
    }
}
