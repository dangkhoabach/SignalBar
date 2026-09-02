import Testing
@testable import DKB_Monitor

// Only the "/system" route is exercised here - the "/targets/<id>" branch
// reaches into `OverviewViewModel.shared`, which is backed by the real
// production database file (`AppDatabaseLocation.productionPath()`); a unit
// test must not touch that.
@MainActor
@Suite struct AppNavigationStateTests {
    @Test func systemRouteSelectsSystemSidebarSection() {
        let state = AppNavigationState.shared
        state.sidebarSelection = .domains

        state.handleNotificationRoute("/system")

        #expect(state.sidebarSelection == .system)
    }

    @Test func unrecognizedRouteIsANoOp() {
        let state = AppNavigationState.shared
        state.sidebarSelection = .domains
        state.pendingDetailTargetID = nil

        state.handleNotificationRoute("/unknown")

        #expect(state.sidebarSelection == .domains)
        #expect(state.pendingDetailTargetID == nil)
    }
}
