import Foundation

public struct LatencyPercentiles: Sendable, Equatable {
    /// The typical response: half of the successful checks were faster.
    public let p50: Int
    /// The slow tail: one check in twenty was slower than this. It is the
    /// figure that corresponds to what people actually notice, which the
    /// latest reading alone never shows.
    public let p95: Int
    /// How many successful checks these were computed from — shown, because
    /// a p95 over eleven samples deserves less trust than one over five
    /// hundred.
    public let sampleCount: Int
}

public enum LatencyStatistics {
    /// Percentiles over the **successful** checks only.
    ///
    /// Failed checks carry a response time too, and it measures something
    /// else entirely: a timeout records the full wait before giving up, and
    /// a refused connection comes back in a millisecond or two. Mixing them
    /// in moves the numbers in both directions at once — an outage of
    /// timeouts inflates p95 into a latency problem that isn't one, while an
    /// outage of instant refusals drags p50 *down* and makes the target look
    /// faster than ever precisely while it is down.
    ///
    /// Returns `nil` when nothing succeeded, since there is no latency to
    /// report rather than a latency of zero.
    public static func percentiles(of results: [CheckResult]) -> LatencyPercentiles? {
        let samples = results
            .filter(\.success)
            .compactMap(\.responseTimeMs)
            .sorted()
        guard !samples.isEmpty else { return nil }

        return LatencyPercentiles(
            p50: nearestRank(samples, percentile: 50),
            p95: nearestRank(samples, percentile: 95),
            sampleCount: samples.count
        )
    }

    /// Nearest-rank: the smallest observed value that at least `percentile`
    /// percent of the samples are less than or equal to.
    ///
    /// Chosen over interpolating between neighbours because every value it
    /// returns is a reading that actually happened. An interpolated p95 of
    /// 437ms is a number no check ever produced, which is a strange thing to
    /// show next to a chart of the individual checks themselves.
    ///
    /// `samples` must already be sorted ascending.
    static func nearestRank(_ samples: [Int], percentile: Double) -> Int {
        let rank = Int((percentile / 100 * Double(samples.count)).rounded(.up))
        return samples[min(max(rank - 1, 0), samples.count - 1)]
    }
}
