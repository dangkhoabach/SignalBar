import DKBMonitorCore
import Foundation
import Observation

/// Where the overlay's numbers come from; a protocol only so tests can feed
/// fixed samples instead of reading this Mac's sensors.
protocol OverlaySampling: Sendable {
    func snapshotOverlay(metrics: Set<OverlayMetric>) async -> OverlaySample
}

extension SystemStatsService: OverlaySampling {}

/// Samples on the overlay's own interval. Same `Task.sleep` loop as
/// `MenuBarStatsViewModel`; `stop()` cancels the task outright, so a hidden
/// overlay costs no wake-ups at all.
///
/// Owns its own `SystemStatsService`: CPU load and network speed are deltas
/// against that instance's previous call, and sharing one with the 5 s menu
/// bar loop would mix two intervals into both readings.
@MainActor
@Observable
final class OverlayViewModel {
    private(set) var sample = OverlaySample()

    /// Refresh rate of the screen the overlay is on, set by the window
    /// controller: `NSScreen` is main-thread only, the sampler is not.
    var displayHz: Int? {
        didSet { sample.displayHz = displayHz }
    }

    /// Recent values for the sparklines, kept only while they are switched
    /// on. Fixed-size rings, so an overlay left on all day never grows.
    private(set) var histories: [OverlayMetric: OverlayRing] = [:]

    /// The metrics that can draw a sparkline: the ones where a trend over
    /// the last minute means something.
    static let historyMetrics: [OverlayMetric] = [.cpu, .gpu, .memory, .network]

    /// The metrics on screen; the sampler skips the SMC reads for the rest.
    @ObservationIgnored var metrics = Set(OverlayMetric.allCases)

    @ObservationIgnored var recordsHistory = false {
        didSet { if !recordsHistory { histories = [:] } }
    }

    /// True while the user is dragging the overlay into place; the view
    /// draws a dashed outline so the mode is visible.
    var isUnlocked = false

    /// Why the overlay's global shortcut could not be registered, if it
    /// could not; shown under the shortcut in Settings.
    var hotkeyError: String?

    /// Called after each new sample, for the window controller's
    /// follow-the-pointer check.
    @ObservationIgnored var onSample: (() -> Void)?

    @ObservationIgnored private let sampler: OverlaySampling
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private(set) var intervalMillis = 0

    var isRunning: Bool { loopTask != nil }

    init(sampler: OverlaySampling) {
        self.sampler = sampler
    }

    /// Starts sampling, or restarts at a new interval. Calling it again with
    /// the interval already running does nothing.
    func start(intervalMillis: Int) {
        guard !isRunning || intervalMillis != self.intervalMillis else { return }
        stop()
        self.intervalMillis = intervalMillis
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .milliseconds(intervalMillis))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func refresh() async {
        var next = await sampler.snapshotOverlay(metrics: metrics)
        guard !Task.isCancelled else { return }
        next.displayHz = displayHz
        sample = next
        if recordsHistory { record(next) }
        onSample?()
    }

    private func record(_ sample: OverlaySample) {
        func add(_ metric: OverlayMetric, _ value: Double?) {
            guard let value else { return }
            histories[metric, default: OverlayRing()].append(value)
        }
        add(.cpu, sample.cpuPercent)
        add(.gpu, sample.gpuPercent)
        if let used = sample.ramUsedMB, let total = sample.ramTotalMB, total > 0 {
            add(.memory, Double(used) / Double(total) * 100)
        }
        if let down = sample.downloadKbps, let up = sample.uploadKbps {
            add(.network, down + up)
        }
    }

    /// For `LayoutSnapshot` only: shows a fabricated sample and history
    /// without running the sampler.
    func overrideForSnapshot(sample: OverlaySample, histories: [OverlayMetric: OverlayRing]) {
        stop()
        self.sample = sample
        self.histories = histories
    }
}
