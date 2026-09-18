import Foundation
import Testing
@testable import DKBMonitorCore
@testable import DKB_Monitor

@Suite struct SystemStatsServiceTests {
    /// Shape of the `ioreg -c IOAccelerator` line the reading is pulled from.
    @Test func readsTheUtilisationPercentageFromIoregOutput() {
        let output = #"  | | "PerformanceStatistics" = {"Device Utilization %"=37,"Alloc system memory"=12}"#
        #expect(SystemStatsService.parseGPUPercent(output) == 37)
    }

    @Test func readsZeroAsARealReadingRatherThanNothing() {
        #expect(SystemStatsService.parseGPUPercent(#""Device Utilization %"=0,"# ) == 0)
    }

    /// A Mac whose `ioreg` reports no accelerator, and the case where the
    /// process itself produced nothing — both mean "no reading", not zero.
    @Test func reportsNothingWhenTheKeyOrTheOutputIsAbsent() {
        #expect(SystemStatsService.parseGPUPercent("no accelerator here") == nil)
        #expect(SystemStatsService.parseGPUPercent("") == nil)
        #expect(SystemStatsService.parseGPUPercent(nil) == nil)
    }

    /// A truncated line must not read as a number.
    @Test func reportsNothingWhenTheValueIsMissing() {
        #expect(SystemStatsService.parseGPUPercent(#""Device Utilization %"="#) == nil)
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
