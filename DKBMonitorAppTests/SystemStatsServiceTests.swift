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
}
