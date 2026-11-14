import Foundation
import GRDB
import Testing
@testable import SignalBarCore
@testable import SignalBar

@MainActor
@Suite struct NetworkViewModelTests {
    private let now = Date()

    private func device(_ id: Int64, ip: String?, mac: String?, state: NetworkDeviceState, vendor: String? = nil, ignored: Bool = false) -> NetworkDevice {
        NetworkDevice(id: id, subnetID: 1, mac: mac, currentIP: ip, vendor: vendor, isIgnored: ignored, state: state,
                      firstSeenAt: now, lastSeenAt: state == .unknown ? nil : now)
    }

    private func lease(_ ip: String, reserved: Bool = false, active: Bool = true) -> NetworkDHCPLease {
        NetworkDHCPLease(sourceID: 1, ip: ip, mac: "00:11:22:33:44:55", hostname: nil, endsAt: nil, isActive: active, isReserved: reserved, syncedAt: now)
    }

    private func model(scanMode: SubnetScanMode) -> (NetworkViewModel, NetworkSubnet) {
        let model = NetworkViewModel(database: nil)
        let subnet = NetworkSubnet(id: 1, name: "Lab", cidr: "10.0.20.0/29", lastScanAt: now,
                                   lastScanStatus: .completed, lastScanMode: scanMode)
        model.subnets = [subnet]
        model.devices = [
            device(1, ip: "10.0.20.1", mac: "a4:83:e7:00:00:01", state: .online),
            device(2, ip: "10.0.20.2", mac: "a4:83:e7:00:00:02", state: .offline),
        ]
        model.leases = [lease("10.0.20.3", reserved: true), lease("10.0.20.4")]
        model.recentEvents = [NetworkEvent(deviceID: 1, subnetID: 1, kind: .conflict, ip: "10.0.20.5", detail: "2", createdAt: now)]
        return (model, subnet)
    }

    /// Free is a claim that nothing is there, so it's only made right after
    /// this Mac looked at its own link; anywhere else silence is unknown.
    @Test func addressStatesFollowWhatIsActuallyKnown() {
        let (direct, subnet) = model(scanMode: .direct)
        #expect(direct.addresses(of: subnet).map(\.state) == [.used, .assigned, .reserved, .assigned, .conflict, .free])

        let (routed, routedSubnet) = model(scanMode: .routed)
        #expect(routed.addresses(of: routedSubnet).last?.state == .unknown)

        var stale = subnet
        stale.lastScanAt = now.addingTimeInterval(-Double(subnet.scanIntervalSecs) * 3)
        #expect(direct.addresses(of: stale).last?.state == .unknown)
    }

    @Test func devicesAreFilteredAndSearched() {
        let model = NetworkViewModel(database: nil)
        model.subnets = [NetworkSubnet(id: 1, name: "Lab", cidr: "10.0.20.0/24")]
        model.devices = [
            device(1, ip: "10.0.20.10", mac: "a4:83:e7:00:00:01", state: .online, vendor: "Example Corp"),
            device(2, ip: "10.0.20.2", mac: "00:11:22:00:00:02", state: .offline),
            device(3, ip: "10.0.20.3", mac: "00:11:22:00:00:03", state: .online, ignored: true),
        ]
        model.recentEvents = [NetworkEvent(deviceID: 2, kind: .discovered, createdAt: now)]

        // Sorted by address as numbers, not text: .2 before .10. Hidden ones left out.
        #expect(model.filteredRows.map(\.id) == [2, 1])
        model.searchText = "example"
        #expect(model.filteredRows.map(\.id) == [1])
        model.searchText = "00:11:22"
        #expect(model.filteredRows.map(\.id) == [2])
        model.searchText = ""
        model.filter = .new
        #expect(model.filteredRows.map(\.id) == [2])
        model.filter = .online
        #expect(model.filteredRows.map(\.id) == [1])
        model.filter = .hidden
        #expect(model.filteredRows.map(\.id) == [3])
        #expect(model.summary == NetworkViewModel.Summary(total: 2, online: 1, offline: 1, new: 1, conflicts: 0))
    }

    @Test func csvFieldsAreQuotedOnlyWhenTheyNeedIt() {
        #expect(NetworkViewModel.csvField("plain") == "plain")
        #expect(NetworkViewModel.csvField("a,b") == "\"a,b\"")
        #expect(NetworkViewModel.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test func portListsAcceptSinglesAndRangesWithinLimits() {
        #expect(NetworkDeviceDetailView.parsePorts("22, 80 443") == [22, 80, 443])
        #expect(NetworkDeviceDetailView.parsePorts("8000-8003,22,22") == [22, 8000, 8001, 8002, 8003])
        #expect(NetworkDeviceDetailView.parsePorts("0, 70000, abc, 5-3") == [])
        #expect(NetworkDeviceDetailView.parsePorts("1-65535").count == 1_024)
    }

    @Test func networkRoutesOpenTheirPages() {
        let state = AppNavigationState.shared
        state.handleNotificationRoute("/network/devices/7")
        #expect(state.sidebarSelection == .networkDevices)
        #expect(state.pendingDeviceID == 7)
        state.pendingDeviceID = nil

        state.handleNotificationRoute("/network/sources/3")
        #expect(state.sidebarSelection == .networks)
        #expect(state.pendingSourceID == 3)
        state.pendingSourceID = nil

        state.openNewServer(name: "NAS", host: "10.0.20.9")
        #expect(state.sidebarSelection == .remoteServers)
        #expect(state.pendingNewServer == AppNavigationState.Prefill(name: "NAS", address: "10.0.20.9"))
        state.pendingNewServer = nil
        state.sidebarSelection = .domains
    }

    /// Network problems turn the icon red only when the user asked for it.
    @Test func networkProblemsReachTheIconOnlyWhenAskedFor() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = NetworkRepository(dbQueue: app.dbQueue)
        let settings = SettingsRepository(dbQueue: app.dbQueue)
        let subnet = try #require(try repo.save(NetworkSubnet(name: "Lab", cidr: "10.0.20.0/24")).id)
        let observation = HostObservation(ip: IPv4Address("10.0.20.5")!, mac: MACAddress("a4:83:e7:00:00:05"), source: .arpSNMP)
        try repo.apply([observation], toSubnet: subnet, isCoverageRun: true)
        var watched = try #require(try repo.devices().first)
        watched.isWatched = true
        try repo.updateUserFields(of: watched)
        for _ in 0..<NetworkRepository.offlineAfterMissedScans { try repo.apply([], toSubnet: subnet, isCoverageRun: true) }

        let model = MenuBarStatusViewModel(targetRepo: TargetRepository(dbQueue: app.dbQueue), networkRepo: repo, settingsRepo: settings)
        model.refresh()
        #expect(model.network?.watchedOffline == 1)
        #expect(!model.showsWarning)

        var values = try settings.load()
        values.networkInMenuBarStatus = true
        try settings.update(values)
        model.refresh()
        #expect(model.showsWarning)
    }
}
