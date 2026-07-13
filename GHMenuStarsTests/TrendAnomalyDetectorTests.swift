import XCTest
@testable import GHMenuStars

final class TrendAnomalyDetectorTests: XCTestCase {
    private let dayInterval: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds cumulative daily trend points from a list of per-day star gains.
    /// The first point is the collapsed baseline (no increment of its own).
    private func points(baseline: Int = 500, gains: [Int]) -> [RepoTrendPoint] {
        var running = baseline
        var result = [RepoTrendPoint(date: start, stars: running, forks: 0)]
        for (index, gain) in gains.enumerated() {
            running += gain
            result.append(RepoTrendPoint(date: start.addingTimeInterval(Double(index + 1) * dayInterval), stars: running, forks: 0))
        }
        return result
    }

    func testFlatHistoryHasNoAnomalies() {
        let series = points(gains: Array(repeating: 0, count: 40))
        XCTAssertTrue(TrendAnomalyDetector.anomalies(in: series).isEmpty)
    }

    func testSingleSharpSpikeIsFlagged() {
        var gains = Array(repeating: 1, count: 40)
        gains[30] = 50
        let series = TrendAnomalyDetector.anomalies(in: points(gains: gains))

        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.gain, 50)
        // Point index 31 (baseline + 31 gains) carries the spike day.
        XCTAssertEqual(series.first?.date, start.addingTimeInterval(31 * dayInterval))
        XCTAssertEqual(series.first?.multipleOfNormal ?? 0, 50, accuracy: 0.001)
    }

    func testSustainedSteadyGrowthDoesNotFlag() {
        // A repo gaining a constant 20/day should read as normal, not spiking.
        let series = points(gains: Array(repeating: 20, count: 40))
        XCTAssertTrue(TrendAnomalyDetector.anomalies(in: series).isEmpty)
    }

    func testShortHistoryReturnsNothing() {
        let series = points(gains: [5, 8, 3, 6])
        XCTAssertTrue(TrendAnomalyDetector.anomalies(in: series).isEmpty)
    }

    func testFlatWindowJumpFlaggedViaFloor() {
        // Ten quiet days then a modest jump: no spread to score against, so the
        // absolute-floor fallback catches it.
        var gains = Array(repeating: 0, count: 10)
        gains.append(10)
        let series = TrendAnomalyDetector.anomalies(in: points(gains: gains))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.gain, 10)
    }

    func testNegativeIncrementIsClampedAndNotFlagged() {
        var gains = Array(repeating: 1, count: 20)
        gains[15] = -8 // a GitHub count correction
        let anomalies = TrendAnomalyDetector.anomalies(in: points(gains: gains))
        XCTAssertTrue(anomalies.isEmpty)
        let daily = TrendAnomalyDetector.dailyGains(points(gains: gains))
        XCTAssertEqual(daily[15].gain, 0)
    }

    func testBestDayPicksLargestIncrement() {
        var gains = Array(repeating: 2, count: 20)
        gains[12] = 142
        let best = TrendAnomalyStats.bestDay(in: points(gains: gains))
        XCTAssertEqual(best?.gain, 142)
        XCTAssertEqual(best?.date, start.addingTimeInterval(13 * dayInterval))
    }

    func testBestDayNilOnShortHistory() {
        XCTAssertNil(TrendAnomalyStats.bestDay(in: points(gains: [3, 4, 5])))
    }

    func testPeakWeekFindsLargestSevenDayGain() {
        var gains = Array(repeating: 2, count: 30)
        for index in 10..<17 { gains[index] = 100 } // a hot week
        let series = points(gains: gains)
        let peak = TrendAnomalyStats.peakWeek(in: series)

        // Brute-force the expected maximum 7-day (≤7·86400s apart) gain.
        let sorted = series.sorted { $0.date < $1.date }
        var expected = 0
        for i in 0..<sorted.count {
            for j in i..<sorted.count where sorted[j].date.timeIntervalSince(sorted[i].date) <= 7 * dayInterval {
                expected = max(expected, sorted[j].stars - sorted[i].stars)
            }
        }
        XCTAssertEqual(peak?.gain, expected)
        XCTAssertNotNil(peak)
    }

    func testPeakWeekNilOnShortHistory() {
        XCTAssertNil(TrendAnomalyStats.peakWeek(in: points(gains: [1, 2, 3])))
    }
}
