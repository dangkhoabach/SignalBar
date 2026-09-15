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

    /// Unlike "/targets/<id>", this branch touches no view model, so it can
    /// be exercised here in full.
    @Test func serverRouteOpensThatServerInTheServerManager() {
        let state = AppNavigationState.shared
        state.sidebarSelection = .domains
        state.pendingDetailServerID = nil

        state.handleNotificationRoute("/servers/42")

        #expect(state.sidebarSelection == .remoteServers)
        #expect(state.pendingDetailServerID == 42)
        state.pendingDetailServerID = nil
    }

    /// A route the app can't act on must not move the user somewhere
    /// unrelated — a resource alert whose id failed to parse would otherwise
    /// jump to the server list for no reason.
    @Test func aServerRouteWithoutAUsableIDIsIgnored() {
        let state = AppNavigationState.shared
        state.sidebarSelection = .domains
        state.pendingDetailServerID = nil

        state.handleNotificationRoute("/servers/not-a-number")

        #expect(state.sidebarSelection == .domains)
        #expect(state.pendingDetailServerID == nil)
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
