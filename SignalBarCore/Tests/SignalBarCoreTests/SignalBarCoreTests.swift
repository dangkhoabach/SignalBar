import Testing
@testable import SignalBarCore

@Test func packageLoads() {
    #expect(!SignalBarCore.version.isEmpty)
}
