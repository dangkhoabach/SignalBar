import Foundation

/// One row the performance overlay can show. The raw value is what
/// `overlay_metrics` stores, so a case must never be renamed once shipped —
/// a saved list naming a case that no longer exists just drops that row.
///
/// There is no FPS case: macOS offers no way to count another app's frames
/// from outside it. `display` is
/// the refresh rate of the screen the overlay sits on, which is the ceiling
/// every app on that screen is held to.
public enum OverlayMetric: String, CaseIterable, Sendable, Identifiable {
    case cpu, cpuTemp, gpu, gpuTemp, gpuMemory, memory, swap
    case network, fan, battery, power, display, uptime

    public var id: Self { self }

    /// What a fresh install shows, in this order.
    public static let defaultMetrics: [OverlayMetric] = [
        .cpu, .cpuTemp, .gpu, .gpuTemp, .memory, .network, .fan, .battery, .display,
    ]

    /// Comma-separated raw values, the form `overlay_metrics` is stored in.
    public static func csv(_ metrics: [OverlayMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// Reads a stored list back. Unknown ids (written by a newer build) and
    /// repeats are skipped rather than failing the whole list. An empty
    /// string means "never saved" and gives the defaults; a list the user
    /// emptied on purpose is stored as `none`.
    public static func parse(csv: String) -> [OverlayMetric] {
        let trimmed = csv.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultMetrics }
        if trimmed == noneMarker { return [] }
        var seen = Set<OverlayMetric>()
        return trimmed.split(separator: ",").compactMap { part in
            guard let metric = OverlayMetric(rawValue: part.trimmingCharacters(in: .whitespaces)),
                  seen.insert(metric).inserted
            else { return nil }
            return metric
        }
    }

    public static let noneMarker = "none"

    /// `list` with `metric` switched on (added at the end) or off.
    public static func toggling(_ metric: OverlayMetric, in list: [OverlayMetric]) -> [OverlayMetric] {
        list.contains(metric) ? list.filter { $0 != metric } : list + [metric]
    }

    /// `list` with `metric` moved one place up (`-1`) or down (`+1`); unchanged
    /// at either end or when the metric is not in the list.
    public static func moving(_ metric: OverlayMetric, by offset: Int, in list: [OverlayMetric]) -> [OverlayMetric] {
        guard let index = list.firstIndex(of: metric), list.indices.contains(index + offset) else { return list }
        var moved = list
        moved.swapAt(index, index + offset)
        return moved
    }
}
