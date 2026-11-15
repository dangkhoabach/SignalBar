import Foundation
import Testing
@testable import SignalBarCore
@testable import SignalBar

@MainActor
@Suite struct ToolsViewModelTests {
    /// Context menus open Tools with the target filled in; tools that need
    /// another choice first (ports, wake) wait for the user.
    @Test func openingAToolFillsItInAndShowsTheToolsPage() {
        let state = AppNavigationState.shared
        let tools = ToolsViewModel.shared
        state.openTool(.wake, target: "00:11:22:33:44:55")
        #expect(state.sidebarSelection == .tools)
        #expect(tools.tool == .wake)
        #expect(tools.wakeMAC == "00:11:22:33:44:55")

        state.openTool(.ports, target: "192.0.2.10")
        #expect(tools.tool == .ports)
        #expect(tools.portHost == "192.0.2.10")
        #expect(!tools.isCheckingPorts)
        state.sidebarSelection = .domains
    }

    @Test func aBadMACIsExplainedNotSent() {
        let tools = ToolsViewModel.shared
        tools.wakeMAC = "not a mac"
        tools.wake()
        #expect(tools.wakeFailed)
    }

    @Test func statusCodesUseTheirStandardPhrase() {
        #expect(HTTPToolReason.phrase(200) == "OK")
        #expect(HTTPToolReason.phrase(404) == "Not Found")
    }
}
