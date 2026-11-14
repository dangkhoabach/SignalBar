import Foundation
import GRDB
import IOKit.ps
import Network

/// Runs the Network feature in the background: scans subnets and polls
/// sources on their schedules, rescans after the Mac changes networks, and
/// turns what changed into alerts.
///
/// Separate from `Scheduler` on purpose. A /20 scan or an SNMP walk of a big
/// switch takes far longer than an HTTP check, and `Scheduler.tick` holds
/// every domain check behind the one in flight; here, a slow scan only ever
/// delays other scans.
public actor NetworkMonitor {
    static let tickIntervalSecs: UInt64 = 30
    /// A network change is acted on once it has held this long, so joining a
    /// network that takes a few seconds to settle triggers one scan, not five.
    static let networkChangeSettleSecs: TimeInterval = 30
    /// A scan refused for lack of Local Network access is tried again this
    /// soon, a few times: the refusal is usually the moment macOS shows its
    /// permission prompt, and the user is about to click Allow.
    static let deniedRetryDelaySecs: UInt64 = 15
    static let deniedRetries = 4

    public static let commonPorts = [22, 53, 80, 443, 445, 3389, 8080, 8443]
    public static let extendedPorts = [21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 443, 445, 515, 548, 554, 631, 993, 995,
                                       1433, 1883, 3306, 3389, 5000, 5432, 5900, 6379, 8006, 8080, 8443, 8883, 9100, 27017]

    private let repo: NetworkRepository
    private let settingsRepo: SettingsRepository
    private let poller: NetworkSourcePoller
    private let scanner: SubnetScanning
    private let notifier: NotificationSending
    private let webhookSender: AlertWebhookSending
    private let alertText: AlertTextLocalizing
    private let isOnBattery: @Sendable () -> Bool

    private var loopTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var hasSeenFirstPath = false
    private var networkChangedAt: Date?
    private var lastCleanup: Date?
    private var tickInFlight = false
    private var scanTasks: [Int64: Task<Void, Never>] = [:]
    private var deniedRetriesLeft: [Int64: Int] = [:]
    private var pollingSources: Set<Int64> = []

    public init(
        dbQueue: DatabaseQueue,
        notifier: NotificationSending,
        webhookSender: AlertWebhookSending? = nil,
        alertText: AlertTextLocalizing = EnglishAlertText(),
        scanner: SubnetScanning = SubnetScanner(),
        poller: NetworkSourcePoller? = nil,
        isOnBattery: @escaping @Sendable () -> Bool = NetworkMonitor.isOnBatteryPower
    ) {
        self.repo = NetworkRepository(dbQueue: dbQueue)
        self.settingsRepo = SettingsRepository(dbQueue: dbQueue)
        self.poller = poller ?? NetworkSourcePoller(dbQueue: dbQueue)
        self.scanner = scanner
        self.notifier = notifier
        self.webhookSender = webhookSender ?? WebhookAlertSender(dbQueue: dbQueue)
        self.alertText = alertText
        self.isOnBattery = isOnBattery
    }

    public func start() {
        guard loopTask == nil else { return }
        try? repo.closeAbandonedScans()
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: Self.tickIntervalSecs * 1_000_000_000)
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.pathDidChange() }
        }
        monitor.start(queue: DispatchQueue(label: "SignalBar.NetworkMonitor.path"))
        pathMonitor = monitor
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        scanTasks.values.forEach { $0.cancel() }
    }

    private func pathDidChange() {
        // The monitor reports the current path as soon as it starts; only
        // later updates are changes.
        guard hasSeenFirstPath else {
            hasSeenFirstPath = true
            return
        }
        networkChangedAt = Date()
    }

    /// One scheduling pass: everything due, scans and polls side by side.
    /// Also called when the Mac wakes.
    public func tick() async {
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let now = Date()
        if lastCleanup.map({ now.timeIntervalSince($0) > 86_400 }) ?? true {
            try? repo.cleanUp(now: now)
            lastCleanup = now
        }
        guard let settings = try? settingsRepo.load(), settings.networkMonitoringEnabled else { return }
        if settings.networkPauseOnBattery, isOnBattery() { return }

        var afterChange: [IPv4CIDR] = []
        if let changed = networkChangedAt, now.timeIntervalSince(changed) >= Self.networkChangeSettleSecs {
            networkChangedAt = nil
            if settings.networkScanOnNetworkChange {
                afterChange = LocalNetworkContext.interfaces().map(\.network)
            }
        }

        let subnets = ((try? repo.subnets()) ?? []).filter { subnet in
            guard subnet.scanEnabled, let id = subnet.id, scanTasks[id] == nil, let network = subnet.network else { return false }
            let due = subnet.lastScanAt.map { now.timeIntervalSince($0) >= Double(subnet.scanIntervalSecs) } ?? true
            return due || afterChange.contains { $0.overlaps(network) }
        }
        let sources = ((try? repo.sources()) ?? []).filter { source in
            guard source.enabled, source.kind != .dhcpImport, let id = source.id, !pollingSources.contains(id) else { return false }
            return source.lastPollAt.map { now.timeIntervalSince($0) >= Double(source.pollIntervalSecs) } ?? true
        }

        async let scans: Void = scanInOrder(subnets, trigger: afterChange.isEmpty ? "scheduled" : "network_change")
        async let polls: Void = pollInOrder(sources)
        _ = await (scans, polls)
    }

    private func scanInOrder(_ subnets: [NetworkSubnet], trigger: String) async {
        for subnet in subnets where !Task.isCancelled {
            await scan(subnet, trigger: trigger)
        }
    }

    private func pollInOrder(_ sources: [NetworkSource]) async {
        for source in sources where !Task.isCancelled {
            await poll(source)
        }
    }

    // MARK: - Scans

    /// A scan the user asked for; runs whether or not scheduling is on.
    public func scanNow(subnetID: Int64) async {
        guard let subnet = try? repo.subnets().first(where: { $0.id == subnetID }) else { return }
        await scan(subnet, trigger: "manual")
    }

    public func cancelScan(subnetID: Int64) {
        scanTasks[subnetID]?.cancel()
    }

    public func isScanning(subnetID: Int64) -> Bool {
        scanTasks[subnetID] != nil
    }

    private func scan(_ subnet: NetworkSubnet, trigger: String) async {
        guard let id = subnet.id, scanTasks[id] == nil else { return }
        let task = Task { await self.performScan(subnet, trigger: trigger) }
        scanTasks[id] = task
        await task.value
        scanTasks[id] = nil
    }

    private func performScan(_ subnet: NetworkSubnet, trigger: String) async {
        guard let id = subnet.id, let network = subnet.network,
              let record = try? repo.beginScan(subnetID: id, trigger: trigger)
        else { return }
        let settings = (try? settingsRepo.load()) ?? .defaults
        let outcome = await scanner.scan(network, resolveNames: settings.networkResolveNames)

        if Task.isCancelled {
            try? repo.finishScan(record, status: .cancelled, outcome: nil)
            return
        }
        if let problem = outcome.problem {
            // Nothing was learned, so nothing about the devices changes:
            // a refused scan must not count as every device missing.
            let status: NetworkScanStatus = problem == .localNetworkDenied ? .localNetworkDenied : .noRoute
            try? repo.finishScan(record, status: status, outcome: outcome)
            if problem == .localNetworkDenied { retryAfterDenial(subnet) }
            return
        }
        deniedRetriesLeft[id] = nil
        do {
            let result = try repo.apply(outcome.observations, toSubnet: id, isCoverageRun: true)
            try repo.finishScan(record, status: .completed, outcome: outcome)
            await sendAlerts(for: result, settings: settings)
        } catch {
            try? repo.finishScan(record, status: .failed, outcome: outcome)
        }
    }

    private func retryAfterDenial(_ subnet: NetworkSubnet) {
        guard let id = subnet.id else { return }
        let left = deniedRetriesLeft[id] ?? Self.deniedRetries
        guard left > 0 else { return }
        deniedRetriesLeft[id] = left - 1
        Task {
            try? await Task.sleep(nanoseconds: Self.deniedRetryDelaySecs * 1_000_000_000)
            await self.scan(subnet, trigger: "retry")
        }
    }

    // MARK: - Sources

    public func pollNow(sourceID: Int64) async {
        guard let source = try? repo.source(id: sourceID) else { return }
        await poll(source)
    }

    public func isPolling(sourceID: Int64) -> Bool {
        pollingSources.contains(sourceID)
    }

    private func poll(_ source: NetworkSource) async {
        guard let id = source.id, pollingSources.insert(id).inserted else { return }
        defer { pollingSources.remove(id) }
        let outcome = await poller.poll(source)
        let settings = (try? settingsRepo.load()) ?? .defaults
        for (_, result) in outcome.results {
            await sendAlerts(for: result, settings: settings)
        }
        if let event = outcome.sourceEvent, settings.networkAlertSourceFailures {
            let message: AlertMessage = event.kind == .sourceFailed
                ? .networkSourceFailing(source: source.name, error: event.detail ?? "")
                : .networkSourceRecovered(source: source.name)
            await send(message, route: "/network/sources/\(id)", settings: settings)
        }
    }

    // MARK: - Ports

    /// TCP connects to the chosen ports of one device, only ever on demand
    /// and only to an address inside the device's own managed subnet.
    @discardableResult
    public func scanPorts(deviceID: Int64, ports: [Int]) async throws -> [NetworkPortResult] {
        guard let device = try repo.device(id: deviceID), let ip = device.ipAddress,
              let subnet = try repo.subnets().first(where: { $0.id == device.subnetID }),
              subnet.network?.contains(ip) == true
        else { return [] }
        let targets = Set(ports.filter { (1...65_535).contains($0) }).sorted().map { (ip, UInt16($0)) }
        let probes = await runBlocking { cancel in
            TCPConnectProbe.run(targets, timeout: 1.5, maxInFlight: 32, cancel: cancel)
        }
        guard !Task.isCancelled else { return try repo.portResults(deviceID: deviceID) }
        try repo.recordPortScan(deviceID: deviceID, results: probes.map { (Int($0.port), $0.state, $0.latencyMs) })
        return try repo.portResults(deviceID: deviceID)
    }

    // MARK: - Alerts

    private func sendAlerts(for result: NetworkApplyResult, settings: AppSettings) async {
        for event in result.events {
            guard let deviceID = event.deviceID, let device = try? repo.device(id: deviceID), !device.isIgnored else { continue }
            let address = [device.currentIP ?? event.ip, device.vendor].compactMap { $0 }.joined(separator: " · ")
            let message: AlertMessage? = switch event.kind {
            case .discovered where settings.networkAlertNewDevices && !result.isFirstInventory:
                .networkNewDevice(name: device.name, address: address)
            case .offline where settings.networkAlertWatchedDevices && device.isWatched:
                .networkDeviceOffline(name: device.name, address: address)
            case .online where settings.networkAlertWatchedDevices && device.isWatched:
                .networkDeviceBackOnline(name: device.name, address: address)
            case .conflict where settings.networkAlertConflicts:
                .networkIPConflict(address: event.ip ?? "", devices: conflictNames(device, otherIDs: event.detail))
            default:
                nil
            }
            guard let message, (try? repo.claimAlert(deviceID: deviceID, kind: event.kind)) == true else { continue }
            await send(message, route: "/network/devices/\(deviceID)", settings: settings)
        }
    }

    private func conflictNames(_ device: NetworkDevice, otherIDs: String?) -> String {
        let others = (otherIDs ?? "").split(separator: ",").compactMap { Int64($0) }.compactMap { try? repo.device(id: $0) }
        return ([device] + others).map { [$0.name, $0.mac].compactMap { $0 }.joined(separator: " ") }.joined(separator: " / ")
    }

    /// The same two destinations as every other alert, except that a
    /// Network alert reaches the webhook only when that was asked for.
    private func send(_ message: AlertMessage, route: String, settings: AppSettings) async {
        let (title, body) = alertText.text(for: message)
        if settings.notificationsEnabled {
            await notifier.notify(title: title, body: body, route: route)
        }
        if settings.networkWebhookEnabled {
            await webhookSender.send(title: title, body: body, route: route)
        }
    }

    public static func isOnBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
