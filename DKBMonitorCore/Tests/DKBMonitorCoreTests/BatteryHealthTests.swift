import Testing
@testable import DKBMonitorCore

@Suite struct BatteryHealthTests {
    /// A new cell reads over its design figure; System Information shows
    /// 100%, not 103%.
    @Test func maximumCapacityIsCappedAt100() {
        #expect(BatteryHealth.maxCapacityPercent(fullCharge: 6459, design: 6249) == 100)
    }

    @Test func maximumCapacityIsRoundedToWholePercent() {
        #expect(BatteryHealth.maxCapacityPercent(fullCharge: 5312, design: 6249) == 85)
    }

    @Test func maximumCapacityNeedsADesignFigure() {
        #expect(BatteryHealth.maxCapacityPercent(fullCharge: 6000, design: 0) == nil)
    }

    @Test func aWornCellIsFlaggedForService() {
        #expect(BatteryHealth.condition(flaggedByOS: false, maxCapacityPercent: 79) == .serviceRecommended)
        #expect(BatteryHealth.condition(flaggedByOS: false, maxCapacityPercent: 80) == .normal)
    }

    @Test func theOSFlagWinsEvenWithGoodCapacity() {
        #expect(BatteryHealth.condition(flaggedByOS: true, maxCapacityPercent: 100) == .serviceRecommended)
    }

    /// No capacity figure at all (older firmware) must not read as worn.
    @Test func unknownCapacityIsNormalUnlessFlagged() {
        #expect(BatteryHealth.condition(flaggedByOS: false, maxCapacityPercent: nil) == .normal)
    }
}
