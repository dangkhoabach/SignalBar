import AppKit
import Foundation
import Observation
import SignalBarCore
import UniformTypeIdentifiers

/// One row of the Devices table: the device plus what the table sorts and
/// filters on, worked out once per change rather than per cell.
struct NetworkDeviceRow: Identifiable, Equatable {
    let device: NetworkDevice
    let subnetName: String
    /// The device's own VLAN from a switch, else its subnet's.
    let vlanID: Int?
    let isNew: Bool
    let hasConflict: Bool
    let isStale: Bool

    var id: Int64 { device.id ?? -1 }
    var name: String { device.name }
    var ipSortKey: UInt32 { device.ipAddress?.value ?? UInt32.max }
    var macText: String { device.mac ?? "" }
    var vendorText: String { device.vendor ?? "" }
    var subnetText: String { vlanID.map { "\(subnetName) · VLAN \($0)" } ?? subnetName }
    var lastSeenKey: Date { device.lastSeenAt ?? .distantPast }
    var statusRank: Int {
        if hasConflict { return 0 }
        switch device.state {
        case .offline: return 1
        case .online: return isStale ? 2 : 3
        case .unknown: return 4
        }
    }
}

/// The Network pages' shared state: everything is observed from the
/// database, so a scan or poll finishing anywhere shows up everywhere.
@MainActor
@Observable
final class NetworkViewModel {
    static let shared = NetworkViewModel(database: AppDatabase.shared)

    enum DeviceFilter: String, CaseIterable, Identifiable {
        case all, online, offline, unknown, new, watched, conflicts, hidden
        var id: Self { self }
    }

    /// How long a device counts as "new" and a conflict stays flagged.
    static let recentWindow: TimeInterval = 86_400

    private let repo: NetworkRepository?
    private let poller: NetworkSourcePoller?
    private let remoteRepo: RemoteServerRepository?
    private let secrets = NetworkSourceSecrets()
    private var observations: [Task<Void, Never>] = []

    var subnets: [NetworkSubnet] = []
    var devices: [NetworkDevice] = []
    var sources: [NetworkSource] = []
    var leases: [NetworkDHCPLease] = []
    var recentEvents: [NetworkEvent] = []
    var scanningSubnetIDs: Set<Int64> = []
    var pollingSourceIDs: Set<Int64> = []
    var testingSourceIDs: Set<Int64> = []
    var sourceMessages: [Int64: String] = [:]
    var errorMessage: String?
    var infoMessage: String?

    var searchText = ""
    var filter: DeviceFilter = .all
    var subnetFilter: Int64?
    var selection: Set<Int64> = []
    var sortOrder = [KeyPathComparator(\NetworkDeviceRow.ipSortKey)]

    init(database: AppDatabase?) {
        repo = database.map { NetworkRepository(dbQueue: $0.dbQueue) }
        poller = database.map { NetworkSourcePoller(dbQueue: $0.dbQueue) }
        remoteRepo = database.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    }

    /// Starts observing once; the pages share this model and it stays live
    /// for the app's lifetime, which costs one query per change.
    func start() {
        guard observations.isEmpty, let repo else { return }
        subnets = (try? repo.subnets()) ?? []
        devices = (try? repo.devices()) ?? []
        sources = (try? repo.sources()) ?? []
        leases = (try? repo.leases()) ?? []
        recentEvents = (try? repo.recentEvents(limit: 300)) ?? []
        observations = [
            observe({ repo.observeSubnets() }) { $0.subnets = $1 },
            observe({ repo.observeDevices() }) { $0.devices = $1 },
            observe({ repo.observeSources() }) { $0.sources = $1 },
            observe({ repo.observeLeases() }) { $0.leases = $1 },
            observe({ repo.observeRecentEvents(limit: 300) }) { $0.recentEvents = $1 },
            observe({ repo.observeRunningScans() }) { $0.scanningSubnetIDs = Set($1.map(\.subnetID)) },
        ]
    }

    /// The sequence is made inside the task, as the other view models do:
    /// GRDB's observation sequences can't cross into it.
    private func observe<Values: AsyncSequence>(
        _ makeValues: @escaping @Sendable () -> Values, apply: @escaping @MainActor (NetworkViewModel, Values.Element) -> Void
    ) -> Task<Void, Never> where Values.Element: Sendable {
        Task { [weak self] in
            do {
                for try await value in makeValues() {
                    guard let self, !Task.isCancelled else { break }
                    apply(self, value)
                }
            } catch {
                // Keep the last values on screen if the stream fails.
            }
        }
    }

    // MARK: - Derived

    private var recentCutoff: Date { Date().addingTimeInterval(-Self.recentWindow) }

    var newDeviceIDs: Set<Int64> {
        Set(recentEvents.filter { $0.kind == .discovered && $0.detail != NetworkEvent.firstInventory && $0.createdAt >= recentCutoff }
            .compactMap(\.deviceID))
    }

    var conflictDeviceIDs: Set<Int64> {
        let conflicts = recentEvents.filter { $0.kind == .conflict && $0.createdAt >= recentCutoff }
        var ids = Set(conflicts.compactMap(\.deviceID))
        for event in conflicts {
            for other in (event.detail ?? "").split(separator: ",") { if let id = Int64(other) { ids.insert(id) } }
        }
        return ids
    }

    var conflictAddresses: Set<String> {
        Set(recentEvents.filter { $0.kind == .conflict && $0.createdAt >= recentCutoff }.compactMap(\.ip))
    }

    func subnet(id: Int64) -> NetworkSubnet? { subnets.first { $0.id == id } }
    func source(id: Int64) -> NetworkSource? { sources.first { $0.id == id } }
    func device(id: Int64) -> NetworkDevice? { devices.first { $0.id == id } }

    /// Online but not looked at for a while: whatever covers its subnet has
    /// stopped running, so "online" is old news.
    func isStale(_ device: NetworkDevice, now: Date = Date()) -> Bool {
        guard device.state == .online, let seen = device.lastSeenAt else { return false }
        let interval = Double(subnet(id: device.subnetID)?.scanIntervalSecs ?? 900)
        return now.timeIntervalSince(seen) > max(interval, 900) * 3
    }

    var rows: [NetworkDeviceRow] {
        let newIDs = newDeviceIDs
        let conflictIDs = conflictDeviceIDs
        let byID = Dictionary(uniqueKeysWithValues: subnets.compactMap { subnet in subnet.id.map { ($0, subnet) } })
        return devices.compactMap { device in
            guard let id = device.id else { return nil }
            let subnet = byID[device.subnetID]
            return NetworkDeviceRow(
                device: device, subnetName: subnet?.name ?? "", vlanID: device.vlanID ?? subnet?.vlanID, isNew: newIDs.contains(id),
                hasConflict: conflictIDs.contains(id), isStale: isStale(device)
            )
        }
    }

    var filteredRows: [NetworkDeviceRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            if let subnetFilter, row.device.subnetID != subnetFilter { return false }
            // Hidden devices only show under their own filter, where they
            // can be brought back.
            if row.device.isIgnored != (filter == .hidden) { return false }
            switch filter {
            case .all, .hidden: break
            case .online: if row.device.state != .online { return false }
            case .offline: if row.device.state != .offline { return false }
            case .unknown: if row.device.state != .unknown { return false }
            case .new: if !row.isNew { return false }
            case .watched: if !row.device.isWatched { return false }
            case .conflicts: if !row.hasConflict { return false }
            }
            guard !query.isEmpty else { return true }
            return [row.name, row.device.currentIP, row.device.mac, row.device.hostname, row.device.vendor, row.device.notes, row.device.switchPort]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
        .sorted(using: sortOrder)
    }

    struct Summary: Equatable {
        var total = 0
        var online = 0
        var offline = 0
        var new = 0
        var conflicts = 0
    }

    var summary: Summary {
        let visible = devices.filter { !$0.isIgnored }
        return Summary(
            total: visible.count,
            online: visible.filter { $0.state == .online }.count,
            offline: visible.filter { $0.state == .offline }.count,
            new: newDeviceIDs.count,
            conflicts: conflictAddresses.count
        )
    }

    var lastScanAt: Date? { subnets.compactMap(\.lastScanAt).max() }

    /// Subnets of this Mac's own interfaces that aren't managed yet.
    var localSuggestions: [IPv4CIDR] {
        let managed = subnets.compactMap(\.network)
        return LocalNetworkContext.interfaces().map(\.network).filter { candidate in
            candidate.isManageable && candidate.prefixLength >= NetworkRepository.largestPrefix
                && !managed.contains { $0.overlaps(candidate) }
        }
    }

    /// The remote servers a DHCP lease file can be read from.
    var remoteServers: [RemoteServer] { (try? remoteRepo?.list()) ?? [] }

    // MARK: - Subnets

    @discardableResult
    func save(_ subnet: NetworkSubnet) -> Bool {
        guard let repo else { return false }
        do {
            let isNew = subnet.id == nil
            let saved = try repo.save(subnet)
            if isNew, saved.scanEnabled, let id = saved.id { scan(subnetID: id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSubnet(id: Int64) {
        cancelScan(subnetID: id)
        try? repo?.deleteSubnet(id: id)
    }

    func scan(subnetID: Int64) {
        guard let monitor = AppNetworkMonitor.shared else { return }
        Task { await monitor.scanNow(subnetID: subnetID) }
    }

    func scanAll() {
        for subnet in subnets where subnet.scanEnabled {
            if let id = subnet.id { scan(subnetID: id) }
        }
    }

    func cancelScan(subnetID: Int64) {
        guard let monitor = AppNetworkMonitor.shared else { return }
        Task { await monitor.cancelScan(subnetID: subnetID) }
    }

    // MARK: - Sources

    /// Saves a source and its secrets. A DHCP-over-SSH source also puts its
    /// lease file on that server's allowlist, which is what lets the SSH
    /// action read it at all.
    @discardableResult
    func save(_ source: NetworkSource, secrets values: [KeychainSecretKind: String]) -> Bool {
        guard let repo else { return false }
        do {
            if source.kind == .dhcpSSH, let serverID = source.remoteServerID, let path = source.leasePath {
                guard RemoteCommandExecutor.isValidLogPath(path) else {
                    errorMessage = AppLocale.string("The lease file must be an absolute path without spaces or \"..\".")
                    return false
                }
                if let previous = source.id.flatMap({ try? repo.source(id: $0) }), previous.leasePath != path || previous.remoteServerID != serverID {
                    removeAllowlistEntry(for: previous)
                }
                let allowlist = (try? remoteRepo?.allowlist(serverId: serverID)) ?? []
                if !allowlist.contains(where: { $0.kind == .dhcpLeaseFile && $0.value == path }) {
                    try remoteRepo?.addAllowlistEntry(serverId: serverID, kind: .dhcpLeaseFile, value: path)
                }
            }
            for (kind, value) in values {
                try secrets.store(value, kind: kind, ref: source.keychainRef)
            }
            let saved = try repo.save(source)
            if saved.enabled, saved.kind != .dhcpImport, let id = saved.id { poll(sourceID: id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSource(_ source: NetworkSource) {
        guard let id = source.id else { return }
        removeAllowlistEntry(for: source)
        secrets.deleteAll(ref: source.keychainRef)
        try? repo?.deleteSource(id: id)
    }

    private func removeAllowlistEntry(for source: NetworkSource) {
        guard source.kind == .dhcpSSH, let serverID = source.remoteServerID, let path = source.leasePath,
              let entry = try? remoteRepo?.allowlist(serverId: serverID).first(where: { $0.kind == .dhcpLeaseFile && $0.value == path }),
              let entryID = entry.id
        else { return }
        try? remoteRepo?.removeAllowlistEntry(id: entryID)
    }

    func hasSecret(_ kind: KeychainSecretKind, for source: NetworkSource) -> Bool {
        secrets.read(kind, ref: source.keychainRef) != nil
    }

    func poll(sourceID: Int64) {
        guard let monitor = AppNetworkMonitor.shared, pollingSourceIDs.insert(sourceID).inserted else { return }
        Task {
            await monitor.pollNow(sourceID: sourceID)
            pollingSourceIDs.remove(sourceID)
        }
    }

    func test(_ source: NetworkSource) {
        guard let poller, let id = source.id, testingSourceIDs.insert(id).inserted else { return }
        sourceMessages[id] = nil
        Task {
            do {
                let answer = try await poller.test(source)
                sourceMessages[id] = source.kind == .snmp
                    ? AppLocale.string("Connected: \(answer)")
                    : AppLocale.string("Connected: \(answer) active leases")
            } catch {
                sourceMessages[id] = error.localizedDescription
            }
            testingSourceIDs.remove(id)
        }
    }

    /// Forgets the pinned router certificate, so the next sync trusts the
    /// one it is shown: for when the router's certificate was renewed.
    func trustCertificateAgain(_ source: NetworkSource) {
        guard let id = source.id else { return }
        try? repo?.setTLSFingerprint(nil, sourceID: id)
        poll(sourceID: id)
    }

    func detectSubnets(_ source: NetworkSource) async -> [IPv4CIDR] {
        guard let poller else { return [] }
        do {
            let managed = subnets.compactMap(\.network)
            return try await poller.detectSubnets(source).filter { candidate in !managed.contains { $0.overlaps(candidate) } }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func importLeases(into source: NetworkSource) {
        guard let poller, let id = source.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = try poller.importLeases(text, format: source.leaseFormat ?? .csv, sourceID: id)
            infoMessage = AppLocale.string("Imported \(count) leases.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Devices

    func update(_ device: NetworkDevice) {
        do {
            try repo?.updateUserFields(of: device)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setWatched(_ watched: Bool, ids: Set<Int64>) {
        for id in ids {
            guard var device = device(id: id) else { continue }
            device.isWatched = watched
            update(device)
        }
    }

    func setIgnored(_ ignored: Bool, ids: Set<Int64>) {
        for id in ids {
            guard var device = device(id: id) else { continue }
            device.isIgnored = ignored
            update(device)
        }
    }

    func deleteDevices(ids: Set<Int64>) {
        for id in ids { try? repo?.deleteDevice(id: id) }
        selection.subtract(ids)
    }

    func merge(_ sourceID: Int64, into targetID: Int64) {
        do {
            try repo?.merge(sourceID, into: targetID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func history(deviceID: Int64) -> [NetworkIPHistoryEntry] { (try? repo?.ipHistory(deviceID: deviceID)) ?? [] }
    func sightings(deviceID: Int64) -> [NetworkSighting] { (try? repo?.sightings(deviceID: deviceID)) ?? [] }
    func events(deviceID: Int64) -> [NetworkEvent] { (try? repo?.events(deviceID: deviceID)) ?? [] }
    func ports(deviceID: Int64) -> [NetworkPortResult] { (try? repo?.portResults(deviceID: deviceID)) ?? [] }
    func interfaces(sourceID: Int64) -> [NetworkSNMPInterface] { (try? repo?.interfaces(sourceID: sourceID)) ?? [] }

    func samples(sourceID: Int64, ifIndex: Int) -> [NetworkSNMPSample] {
        (try? repo?.samples(sourceID: sourceID, ifIndex: ifIndex, since: Date().addingTimeInterval(-86_400))) ?? []
    }

    func leases(for device: NetworkDevice) -> [NetworkDHCPLease] {
        guard let mac = device.mac else { return [] }
        return leases.filter { $0.mac == mac }
    }

    func scanPorts(deviceID: Int64, ports: [Int]) async -> [NetworkPortResult] {
        guard let monitor = AppNetworkMonitor.shared else { return [] }
        do {
            return try await monitor.scanPorts(deviceID: deviceID, ports: ports)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Server Manager entries whose host is a device's address.
    func serverName(for device: NetworkDevice) -> String? {
        guard let ip = device.currentIP else { return nil }
        return remoteServers.first { $0.host == ip }?.name
    }

    // MARK: - IP addresses

    enum AddressState: String, CaseIterable {
        case used, assigned, reserved, conflict, free, unknown
    }

    struct AddressRow: Identifiable {
        let address: IPv4Address
        let state: AddressState
        let device: NetworkDevice?
        let lease: NetworkDHCPLease?
        var id: UInt32 { address.value }
    }

    /// Every address of a subnet and what is known about it. An address is
    /// only called free when a scan of the Mac's own link just looked at it
    /// and nothing answered; anywhere else, silence is "unknown".
    func addresses(of subnet: NetworkSubnet, now: Date = Date()) -> [AddressRow] {
        guard let network = subnet.network, let id = subnet.id else { return [] }
        let subnetDevices = devices.filter { $0.subnetID == id }
        let byIP = Dictionary(subnetDevices.compactMap { device in device.currentIP.map { ($0, device) } }, uniquingKeysWith: { first, second in
            first.state == .online ? first : second
        })
        let leaseByIP = Dictionary(leases.filter { lease in IPv4Address(lease.ip).map(network.contains) ?? false }.map { ($0.ip, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let conflicts = conflictAddresses
        let freshDirectScan = subnet.lastScanMode == .direct && subnet.lastScanStatus == .completed
            && (subnet.lastScanAt.map { now.timeIntervalSince($0) < Double(subnet.scanIntervalSecs) * 2 } ?? false)

        return network.hosts.map { address in
            let key = address.description
            let device = byIP[key]
            let lease = leaseByIP[key]
            let state: AddressState
            if conflicts.contains(key) {
                state = .conflict
            } else if device?.state == .online {
                state = .used
            } else if lease?.isReserved == true {
                state = .reserved
            } else if device != nil || lease?.isActive == true {
                state = .assigned
            } else if freshDirectScan {
                state = .free
            } else {
                state = .unknown
            }
            return AddressRow(address: address, state: state, device: device, lease: lease)
        }
    }

    // MARK: - Export and wipe

    func exportDevicesCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "signalbar-network-devices.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = "name,ip,mac,vendor,hostname,type,state,subnet,vlan,switch,port,first_seen,last_seen,watched,notes"
        let formatter = ISO8601DateFormatter()
        let lines = rows.sorted { $0.ipSortKey < $1.ipSortKey }.map { row -> String in
            let device = row.device
            return [
                device.displayName ?? "", device.currentIP ?? "", device.mac ?? "", device.vendor ?? "", device.hostname ?? "",
                device.deviceType.rawValue, device.state.rawValue, row.subnetName, device.vlanID.map(String.init) ?? "",
                device.switchName ?? "", device.switchPort ?? "", formatter.string(from: device.firstSeenAt),
                device.lastSeenAt.map(formatter.string) ?? "", device.isWatched ? "yes" : "no", device.notes ?? "",
            ].map(Self.csvField).joined(separator: ",")
        }
        do {
            try ([header] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func deleteAllNetworkData() {
        guard let repo else { return }
        for subnet in subnets { if let id = subnet.id { cancelScan(subnetID: id) } }
        do {
            for ref in try repo.deleteAll() { secrets.deleteAll(ref: ref) }
            selection = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
