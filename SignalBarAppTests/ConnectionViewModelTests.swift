import Foundation
import Testing
@testable import SignalBarCore
@testable import SignalBar

@MainActor
@Suite struct ConnectionViewModelTests {
    private typealias Stats = ConnectionViewModel.LatencyStats

    @Test func latencyStatsCountLostPingsAndJitter() {
        let stats = Stats([10, nil, 14, 12, nil])
        #expect(stats.average == 12)
        #expect(stats.jitter == 3) // |14-10| and |12-14|
        #expect(stats.lossPercent == 40)
        #expect(Stats([]).average == nil)
        #expect(Stats([]).lossPercent == 0)
        #expect(Stats([nil, nil]).lossPercent == 100)
    }

    /// The first stretch that adds most of the delay is the one named.
    @Test func slownessIsPlacedOnTheStretchThatAddsIt() {
        let fast = Stats([3, 4, 3])
        #expect(ConnectionViewModel.slowStretch(gateway: fast, provider: Stats([8]), internet: Stats([40])) == nil)
        #expect(ConnectionViewModel.slowStretch(gateway: Stats([60]), provider: Stats([70]), internet: Stats([120])) == .localNetwork)
        #expect(ConnectionViewModel.slowStretch(gateway: Stats([4, nil]), provider: Stats([8]), internet: Stats([40, nil])) == .localNetwork)
        #expect(ConnectionViewModel.slowStretch(gateway: fast, provider: Stats([90]), internet: Stats([120])) == .provider)
        #expect(ConnectionViewModel.slowStretch(gateway: fast, provider: Stats([9]), internet: Stats([150])) == .beyond)
        // A provider hop that never answers can't be blamed.
        #expect(ConnectionViewModel.slowStretch(gateway: fast, provider: Stats([nil]), internet: Stats([150])) == .beyond)
    }

    @Test func reachabilityNeedsSomethingFromTheInternet() {
        var status = ConnectionStatus()
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: nil) == .checking)
        status.path = PathSummary(isSatisfied: false, kind: nil)
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: nil) == .offline)
        status.path = PathSummary(isSatisfied: true, kind: .wifi)
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: nil) == .checking)
        status.refreshedAt = Date()
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: nil) == .noInternet)
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: 20) == .online)
        status.publicIPv4 = PublicAddress(family: .ipv4, ip: "203.0.113.7")
        #expect(ConnectionViewModel.reachability(status, lastInternetPing: nil) == .online)
    }

    @Test func theIPChangeNotificationOpensTheConnectionPage() {
        let state = AppNavigationState.shared
        state.handleNotificationRoute("/network/connection")
        #expect(state.sidebarSelection == .connection)
        state.sidebarSelection = .domains
    }
}
