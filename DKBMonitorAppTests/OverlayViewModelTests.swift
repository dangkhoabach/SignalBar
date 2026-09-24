import Foundation
import Testing
@testable import DKBMonitorCore
@testable import DKB_Monitor

/// Counts calls so a test can tell the loop is actually sampling.
private actor CountingSampler: OverlaySampling {
    private(set) var calls = 0

    func snapshotOverlay(metrics: Set<OverlayMetric>) async -> OverlaySample {
        calls += 1
        return OverlaySample(cpuPercent: 42, gpuPercent: 7)
    }
}

@MainActor
@Suite struct OverlayViewModelTests {
    /// Polls instead of sleeping a fixed time, so a slow CI box waits longer
    /// rather than failing.
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<100 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startSamplesAndCarriesTheDisplayRate() async {
        let model = OverlayViewModel(sampler: CountingSampler())
        model.displayHz = 120
        model.start(intervalMillis: 500)
        await waitUntil { model.sample.cpuPercent != nil }
        #expect(model.sample.cpuPercent == 42)
        #expect(model.sample.displayHz == 120)
        model.stop()
    }

    /// A hidden overlay must leave no task behind: that is what "0 wake-ups
    /// while hidden" means.
    @Test func stopLeavesNothingRunning() async {
        let sampler = CountingSampler()
        let model = OverlayViewModel(sampler: sampler)
        model.start(intervalMillis: 500)
        await waitUntil { await sampler.calls > 0 }
        model.stop()
        #expect(!model.isRunning)
        let callsAtStop = await sampler.calls
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await sampler.calls == callsAtStop)
    }

    /// Re-applying the same settings must not restart the loop, which would
    /// take an extra sample and reset the CPU delta each time.
    @Test func startingAgainAtTheSameIntervalKeepsTheLoop() async {
        let sampler = CountingSampler()
        let model = OverlayViewModel(sampler: sampler)
        model.start(intervalMillis: 5000)
        await waitUntil { await sampler.calls > 0 }
        model.start(intervalMillis: 5000)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await sampler.calls == 1)
        model.stop()
    }

    /// Sparkline history is kept only while sparklines are on, and dropped
    /// when they are switched off so a stale line never reappears.
    @Test func historyIsRecordedOnlyWhileSwitchedOn() async {
        let model = OverlayViewModel(sampler: CountingSampler())
        model.recordsHistory = true
        model.start(intervalMillis: 500)
        await waitUntil { model.histories[.cpu] != nil }
        model.stop()
        #expect(model.histories[.cpu]?.values.last == 42)
        #expect(model.histories[.gpu]?.values.last == 7)
        // No memory or network in this sample: nothing to plot.
        #expect(model.histories[.memory] == nil)

        model.recordsHistory = false
        #expect(model.histories.isEmpty)
    }
}
