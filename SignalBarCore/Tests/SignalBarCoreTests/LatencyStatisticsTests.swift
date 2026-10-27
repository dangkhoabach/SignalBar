import Foundation
import Testing
@testable import SignalBarCore

@Suite struct LatencyStatisticsTests {
    private func checks(_ entries: [(ms: Int?, success: Bool)]) -> [CheckResult] {
        entries.map { CheckResult(targetId: 1, success: $0.success, responseTimeMs: $0.ms) }
    }

    private func successful(_ times: [Int]) -> [CheckResult] {
        checks(times.map { (ms: $0, success: true) })
    }

    // MARK: - Nearest rank

    @Test func percentilesOverAKnownSpread() throws {
        // 1...100, so the expected answers are unambiguous.
        let stats = try #require(LatencyStatistics.percentiles(of: successful(Array(1...100))))
        #expect(stats.p50 == 50)
        #expect(stats.p95 == 95)
        #expect(stats.sampleCount == 100)
    }

    @Test func orderOfTheInputDoesNotMatter() throws {
        let shuffled = try #require(LatencyStatistics.percentiles(of: successful([500, 10, 300, 20, 100])))
        let ordered = try #require(LatencyStatistics.percentiles(of: successful([10, 20, 100, 300, 500])))
        #expect(shuffled == ordered)
    }

    /// Every reported value is one that actually happened, rather than an
    /// interpolation between two readings.
    @Test func theResultIsAlwaysAnObservedValue() throws {
        let samples = [10, 20, 400]
        let stats = try #require(LatencyStatistics.percentiles(of: successful(samples)))
        #expect(samples.contains(stats.p50))
        #expect(samples.contains(stats.p95))
    }

    @Test func aSingleCheckIsItsOwnPercentiles() throws {
        let stats = try #require(LatencyStatistics.percentiles(of: successful([42])))
        #expect(stats.p50 == 42)
        #expect(stats.p95 == 42)
        #expect(stats.sampleCount == 1)
    }

    @Test func nearestRankClampsAtBothEnds() {
        let samples = [10, 20, 30, 40]
        #expect(LatencyStatistics.nearestRank(samples, percentile: 0) == 10)
        #expect(LatencyStatistics.nearestRank(samples, percentile: 100) == 40)
    }

    // MARK: - What counts as a sample

    /// The heart of it: a failed check's response time measures how long
    /// until it gave up, not how fast the site is.
    @Test func timeoutsDoNotInflateTheSlowTail() throws {
        let fast = successful(Array(repeating: 100, count: 19))
        let timedOut = checks([(ms: 30_000, success: false)])
        let stats = try #require(LatencyStatistics.percentiles(of: fast + timedOut))

        #expect(stats.p95 == 100)
        #expect(stats.sampleCount == 19)
    }

    /// And the opposite direction, which is the easier one to miss: a
    /// refused connection returns almost instantly, so counting failures
    /// would make a target look *faster* exactly while it is down.
    @Test func instantFailuresDoNotDragTheTypicalCaseDown() throws {
        let normal = successful(Array(repeating: 200, count: 10))
        let refused = checks(Array(repeating: (ms: 1, success: false), count: 10))
        let stats = try #require(LatencyStatistics.percentiles(of: normal + refused))

        #expect(stats.p50 == 200)
        #expect(stats.sampleCount == 10)
    }

    @Test func checksWithNoRecordedTimeAreSkipped() throws {
        let stats = try #require(LatencyStatistics.percentiles(of: checks([
            (ms: nil, success: true),
            (ms: 50, success: true),
        ])))
        #expect(stats.sampleCount == 1)
        #expect(stats.p50 == 50)
    }

    /// No latency to report is different from a latency of zero.
    @Test func nothingSuccessfulMeansNoResult() {
        #expect(LatencyStatistics.percentiles(of: []) == nil)
        #expect(LatencyStatistics.percentiles(of: checks([(ms: 5_000, success: false)])) == nil)
        #expect(LatencyStatistics.percentiles(of: checks([(ms: nil, success: true)])) == nil)
    }
}
