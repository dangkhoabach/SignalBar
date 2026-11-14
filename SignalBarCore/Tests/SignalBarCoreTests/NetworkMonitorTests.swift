import Foundation
import GRDB
import Testing
@testable import SignalBarCore

private actor ScriptedScanner: SubnetScanning {
    private var outcomes: [SubnetScanOutcome]
    private(set) var scanned: [String] = []

    init(_ outcomes: [SubnetScanOutcome]) {
        self.outcomes = outcomes
    }

    func scan(_ subnet: IPv4CIDR, resolveNames: Bool) async -> SubnetScanOutcome {
        scanned.append(subnet.description)
        return outcomes.isEmpty ? SubnetScanOutcome(mode: .direct, observations: [], probedCount: 0) : outcomes.removeFirst()
    }

    func count() -> Int { scanned.count }
}

private actor Recorder: NotificationSending, AlertWebhookSending {
    private(set) var titles: [String] = []
    private(set) var routes: [String?] = []
    private(set) var webhookTitles: [String] = []

    func notify(title: String, body: String, route: String?) async {
        titles.append(title)
        routes.append(route)
    }

    func send(title: String, body: String, route: String?) async {
        webhookTitles.append(title)
    }
}

@Suite struct NetworkMonitorTests {
    private func observation(_ last: UInt32, _ mac: String) -> HostObservation {
        HostObservation(ip: IPv4Address(0x0A00_1400 + last), mac: MACAddress(mac), source: .arpSNMP)
    }

    private func outcome(_ observations: [HostObservation], problem: SubnetScanProblem? = nil) -> SubnetScanOutcome {
        SubnetScanOutcome(mode: .direct, observations: observations, probedCount: 254, problem: problem)
    }

    private func setUp(
        _ outcomes: [SubnetScanOutcome], configure: (inout AppSettings) -> Void = { _ in }
    ) throws -> (NetworkMonitor, ScriptedScanner, Recorder, NetworkRepository, Int64) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        var settings = AppSettings.defaults
        settings.notificationsEnabled = true
        configure(&settings)
        try SettingsRepository(dbQueue: app.dbQueue).update(settings)
        let repo = NetworkRepository(dbQueue: app.dbQueue)
        let subnet = try #require(try repo.save(NetworkSubnet(name: "Office", cidr: "10.0.20.0/24")).id)
        let scanner = ScriptedScanner(outcomes)
        let recorder = Recorder()
        let monitor = NetworkMonitor(
            dbQueue: app.dbQueue, notifier: recorder, webhookSender: recorder, scanner: scanner,
            poller: NetworkSourcePoller(dbQueue: app.dbQueue, secrets: NetworkSourceSecrets(keychain: InMemoryKeychainStore()),
                                        remoteKeychain: InMemoryKeychainStore()),
            isOnBattery: { false }
        )
        return (monitor, scanner, recorder, repo, subnet)
    }

    @Test func nothingIsScannedOnASchedulePlainlyBecauseItIsOffByDefault() async throws {
        let (monitor, scanner, _, _, subnet) = try setUp([])
        await monitor.tick()
        #expect(await scanner.count() == 0)
        // A scan the user asks for runs anyway.
        await monitor.scanNow(subnetID: subnet)
        #expect(await scanner.count() == 1)
    }

    @Test func scheduledScansRunWhenDueAndAlertOnlyForArrivals() async throws {
        let (monitor, scanner, recorder, repo, _) = try setUp([
            outcome([observation(5, "a4:83:e7:00:00:05")]),
            outcome([observation(5, "a4:83:e7:00:00:05"), observation(6, "a4:83:e7:00:00:06")]),
        ]) { $0.networkMonitoringEnabled = true }

        await monitor.tick()
        #expect(await scanner.count() == 1)
        // The first scan is the starting inventory: no alert for it.
        #expect(await recorder.titles.isEmpty)

        // Not due yet: the interval hasn't passed.
        await monitor.tick()
        #expect(await scanner.count() == 1)

        var subnet = try #require(try repo.subnets().first)
        subnet.lastScanAt = Date().addingTimeInterval(-Double(subnet.scanIntervalSecs) - 1)
        try repo.save(subnet)
        await monitor.tick()
        #expect(await scanner.count() == 2)
        #expect(await recorder.titles == ["New device on the network: 10.0.20.6"])
        #expect(await recorder.routes.first??.hasPrefix("/network/devices/") == true)
        // The webhook stays quiet unless Network alerts were sent there on purpose.
        #expect(await recorder.webhookTitles.isEmpty)
    }

    @Test func aRefusedScanChangesNothing() async throws {
        let (monitor, _, recorder, repo, subnet) = try setUp([
            outcome([observation(5, "a4:83:e7:00:00:05")]),
            outcome([], problem: .localNetworkDenied),
            outcome([], problem: .localNetworkDenied),
            outcome([], problem: .localNetworkDenied),
        ])
        var device = NetworkDevice(subnetID: subnet, mac: nil, currentIP: nil)
        await monitor.scanNow(subnetID: subnet)
        device = try #require(try repo.devices().first)
        device.isWatched = true
        try repo.updateUserFields(of: device)

        for _ in 0..<3 { await monitor.scanNow(subnetID: subnet) }
        #expect(try repo.devices().first?.state == .online)
        #expect(try repo.subnets().first?.lastScanStatus == .localNetworkDenied)
        #expect(await recorder.titles.isEmpty)
    }

    @Test func watchedDevicesAlertWhenTheyLeaveAndComeBack() async throws {
        let present = outcome([observation(5, "a4:83:e7:00:00:05"), observation(6, "a4:83:e7:00:00:06")])
        let gone = outcome([observation(6, "a4:83:e7:00:00:06")])
        let (monitor, _, recorder, repo, subnet) = try setUp([present, gone, gone, gone, present]) {
            $0.networkWebhookEnabled = true
        }
        await monitor.scanNow(subnetID: subnet)
        for var device in try repo.devices() where device.mac == "a4:83:e7:00:00:05" {
            device.isWatched = true
            device.displayName = "NAS"
            try repo.updateUserFields(of: device)
        }
        for _ in 0..<4 { await monitor.scanNow(subnetID: subnet) }
        #expect(await recorder.titles == ["NAS left the network", "NAS is back on the network"])
        #expect(await recorder.webhookTitles == ["NAS left the network", "NAS is back on the network"])
    }

    @Test func nothingRunsOnBatteryWhenAskedNotTo() async throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        var settings = AppSettings.defaults
        settings.networkMonitoringEnabled = true
        settings.networkPauseOnBattery = true
        try SettingsRepository(dbQueue: app.dbQueue).update(settings)
        try NetworkRepository(dbQueue: app.dbQueue).save(NetworkSubnet(name: "Office", cidr: "10.0.20.0/24"))
        let scanner = ScriptedScanner([])
        let monitor = NetworkMonitor(dbQueue: app.dbQueue, notifier: Recorder(), webhookSender: Recorder(), scanner: scanner, isOnBattery: { true })
        await monitor.tick()
        #expect(await scanner.count() == 0)
    }

    @Test func subnetsWithScanningOffAreLeftToOtherSources() async throws {
        let (monitor, scanner, _, repo, _) = try setUp([]) { $0.networkMonitoringEnabled = true }
        var subnet = try #require(try repo.subnets().first)
        subnet.scanEnabled = false
        try repo.save(subnet)
        await monitor.tick()
        #expect(await scanner.count() == 0)
    }
}
