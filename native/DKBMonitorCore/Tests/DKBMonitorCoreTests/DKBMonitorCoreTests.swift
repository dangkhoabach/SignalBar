import Testing
@testable import DKBMonitorCore

@Test func packageLoads() {
    #expect(!DKBMonitorCore.version.isEmpty)
}
