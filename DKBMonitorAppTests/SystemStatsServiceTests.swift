import Foundation
import Testing
@testable import DKBMonitorCore
@testable import DKB_Monitor

@Suite struct SystemStatsServiceTests {
    /// The dictionary `IOAccelerator` publishes as `PerformanceStatistics`.
    @Test func readsUtilisationAndMemoryFromTheStatistics() {
        let stats = GPUStatsReader.parse(["Device Utilization %": 37, "In use system memory": 292_962_304, "Tiler Utilization %": 20])
        #expect(stats == GPUStatsReader.Stats(utilizationPercent: 37, inUseMemoryBytes: 292_962_304))
    }

    @Test func readsZeroAsARealReadingRatherThanNothing() {
        #expect(GPUStatsReader.parse(["Device Utilization %": 0]).utilizationPercent == 0)
    }

    @Test func missingKeysReadAsNothing() {
        #expect(GPUStatsReader.parse([:]) == GPUStatsReader.Stats(utilizationPercent: nil, inUseMemoryBytes: nil))
        #expect(GPUStatsReader.parse(["Device Utilization %": "37"]).utilizationPercent == nil)
    }

    /// Reads the real registry: a Mac either has no accelerator statistics
    /// or reports a percentage, never something outside 0–100.
    @Test func realAcceleratorReportsAPercentageOrNothing() {
        guard let percent = GPUStatsReader().read()?.utilizationPercent else { return }
        #expect((0...100).contains(percent))
    }

    /// CPU load is a delta between two calls, so the second one is the first
    /// real reading. Nothing may come back NaN or out of range, and a Mac
    /// that has a reading at all must keep it within physical bounds.
    @Test func overlaySnapshotReturnsBoundedReadings() async throws {
        let service = SystemStatsService()
        _ = await service.snapshotOverlay()
        try await Task.sleep(for: .milliseconds(200))
        let sample = await service.snapshotOverlay()

        let cpu = try #require(sample.cpuPercent)
        #expect((0...100).contains(cpu))
        #expect((sample.ramTotalMB ?? 0) > 0)
        #expect((sample.ramUsedMB ?? 0) <= (sample.ramTotalMB ?? 0))
        if let gpu = sample.gpuPercent { #expect((0...100).contains(gpu)) }
        for temp in [sample.cpuTempCelsius, sample.gpuTempCelsius].compactMap({ $0 }) {
            #expect((1...150).contains(temp))
        }
        #expect(sample.fanRPMs.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(sample.downloadKbps.map { $0.isFinite && $0 >= 0 } == true)
        // The app fills this from the screen, not the sampler.
        #expect(sample.displayHz == nil)
    }

    /// Reads the real registry: there is no seam under the IOKit calls and
    /// the whole point is whether the keys are where the code expects them.
    /// On a Mac with a battery the wear figures are always present and
    /// bounded; on a desktop the whole thing must be absent, not zeroes.
    @Test func batteryHealthComesWithTheBatteryOrNotAtAll() async {
        let stats = await SystemStatsService().snapshot()
        guard stats.batteryPercent != nil else {
            #expect(stats.batteryHealth == nil)
            return
        }
        let health = try? #require(stats.batteryHealth)
        #expect((health?.maxCapacityPercent).map { (1...100).contains($0) } == true)
        #expect((health?.cycleCount).map { $0 >= 0 } == true)
    }
}
