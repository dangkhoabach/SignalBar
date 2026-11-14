import Foundation
import GRDB

public enum NetworkRepositoryError: Error, Equatable, Sendable {
    case invalidCIDR
    case notInternal
    case tooLarge
    case overlaps(String)
}

extension NetworkRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCIDR: "Enter the subnet as an address and prefix length, for example 192.168.1.0/24."
        case .notInternal: "Only private address ranges can be added: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and the like."
        case .tooLarge: "The largest subnet that can be added is a /20 (4,094 addresses)."
        case .overlaps(let other): "This subnet overlaps \(other), which is already added."
        }
    }
}

/// What applying one batch of observations changed.
public struct NetworkApplyResult: Sendable, Equatable {
    public var events: [NetworkEvent]
    /// The subnet had never had a device seen in it before this batch: its
    /// devices are the starting inventory, not new arrivals worth an alert.
    public var isFirstInventory: Bool
}

/// Storage for the Network feature, including the one piece of logic that
/// has to happen inside a transaction: matching observations to devices.
public struct NetworkRepository: Sendable {
    let dbQueue: DatabaseQueue

    /// Missed runs before an online device is called offline. One silent
    /// run is not evidence: ping is dropped, phones doze.
    public static let offlineAfterMissedScans = 3
    /// An address that bounces back to the device it just left within this
    /// window is two devices fighting over it, not a DHCP reassignment.
    public static let conflictWindow: TimeInterval = 1_800
    public static let largestPrefix = 20

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Subnets

    public func subnets() throws -> [NetworkSubnet] {
        try dbQueue.read { try NetworkSubnet.order(sql: "name COLLATE NOCASE").fetchAll($0) }
    }

    public func observeSubnets() -> AsyncValueObservation<[NetworkSubnet]> {
        ValueObservation.tracking { try NetworkSubnet.order(sql: "name COLLATE NOCASE").fetchAll($0) }.values(in: dbQueue)
    }

    /// Validates and canonicalises `subnet.cidr`, then inserts or updates.
    @discardableResult
    public func save(_ subnet: NetworkSubnet) throws -> NetworkSubnet {
        guard let network = IPv4CIDR(subnet.cidr) else { throw NetworkRepositoryError.invalidCIDR }
        guard network.isManageable else { throw NetworkRepositoryError.notInternal }
        guard network.prefixLength >= Self.largestPrefix else { throw NetworkRepositoryError.tooLarge }
        var saved = subnet
        saved.cidr = network.description
        saved.name = saved.name.trimmingCharacters(in: .whitespaces).isEmpty ? saved.cidr : saved.name
        try dbQueue.write { db in
            for other in try NetworkSubnet.fetchAll(db) where other.id != saved.id {
                if let otherNetwork = other.network, otherNetwork.overlaps(network) {
                    throw NetworkRepositoryError.overlaps("\(other.name) (\(other.cidr))")
                }
            }
            try saved.save(db)
        }
        return saved
    }

    public func deleteSubnet(id: Int64) throws {
        _ = try dbQueue.write { try NetworkSubnet.deleteOne($0, key: id) }
    }

    // MARK: - Devices

    public func devices() throws -> [NetworkDevice] {
        try dbQueue.read { try NetworkDevice.fetchAll($0) }
    }

    public func observeDevices() -> AsyncValueObservation<[NetworkDevice]> {
        ValueObservation.tracking { try NetworkDevice.fetchAll($0) }.values(in: dbQueue)
    }

    public func device(id: Int64) throws -> NetworkDevice? {
        try dbQueue.read { try NetworkDevice.fetchOne($0, key: id) }
    }

    /// Saves the fields the user edits; everything the scans maintain is
    /// re-read inside the transaction so a scan landing meanwhile isn't undone.
    public func updateUserFields(of device: NetworkDevice) throws {
        guard let id = device.id else { return }
        try dbQueue.write { db in
            guard var stored = try NetworkDevice.fetchOne(db, key: id) else { return }
            stored.displayName = device.displayName?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : device.displayName
            stored.deviceType = device.deviceType
            stored.notes = device.notes?.isEmpty == true ? nil : device.notes
            stored.isWatched = device.isWatched
            stored.isIgnored = device.isIgnored
            stored.ignoreConflicts = device.ignoreConflicts
            try stored.update(db)
        }
    }

    public func deleteDevice(id: Int64) throws {
        _ = try dbQueue.write { try NetworkDevice.deleteOne($0, key: id) }
    }

    /// Folds `sourceID` into `targetID`: history, sightings, events and port
    /// results move over, user-entered fields fill gaps, the source goes.
    public func merge(_ sourceID: Int64, into targetID: Int64, now: Date = Date()) throws {
        guard sourceID != targetID else { return }
        try dbQueue.write { db in
            try Self.merge(sourceID, into: targetID, db: db)
            var event = NetworkEvent(deviceID: targetID, kind: .merged, detail: String(sourceID), createdAt: now)
            try event.insert(db)
        }
    }

    private static func merge(_ sourceID: Int64, into targetID: Int64, db: Database) throws {
        guard let source = try NetworkDevice.fetchOne(db, key: sourceID),
              var target = try NetworkDevice.fetchOne(db, key: targetID)
        else { return }
        try db.execute(sql: "UPDATE network_ip_history SET device_id = ? WHERE device_id = ?", arguments: [targetID, sourceID])
        try db.execute(sql: "UPDATE network_events SET device_id = ? WHERE device_id = ?", arguments: [targetID, sourceID])
        try db.execute(sql: "UPDATE OR IGNORE network_sightings SET device_id = ? WHERE device_id = ?", arguments: [targetID, sourceID])
        try db.execute(sql: "UPDATE OR IGNORE network_port_results SET device_id = ? WHERE device_id = ?", arguments: [targetID, sourceID])
        target.displayName = target.displayName ?? source.displayName
        target.notes = target.notes ?? source.notes
        if target.deviceType == .unknown { target.deviceType = source.deviceType }
        target.isWatched = target.isWatched || source.isWatched
        target.ignoreConflicts = target.ignoreConflicts || source.ignoreConflicts
        target.firstSeenAt = min(target.firstSeenAt, source.firstSeenAt)
        if target.hostname == nil {
            target.hostname = source.hostname
            target.hostnameSource = source.hostnameSource
        }
        _ = try NetworkDevice.deleteOne(db, key: sourceID)
        try target.update(db)
    }

    public func ipHistory(deviceID: Int64) throws -> [NetworkIPHistoryEntry] {
        try dbQueue.read {
            try NetworkIPHistoryEntry.filter(sql: "device_id = ?", arguments: [deviceID]).order(sql: "last_seen_at DESC").fetchAll($0)
        }
    }

    public func sightings(deviceID: Int64) throws -> [NetworkSighting] {
        try dbQueue.read {
            try NetworkSighting.filter(sql: "device_id = ?", arguments: [deviceID]).order(sql: "last_seen_at DESC").fetchAll($0)
        }
    }

    public func events(deviceID: Int64, limit: Int = 200) throws -> [NetworkEvent] {
        try dbQueue.read {
            try NetworkEvent.filter(sql: "device_id = ?", arguments: [deviceID]).order(sql: "created_at DESC, id DESC").limit(limit).fetchAll($0)
        }
    }

    public func recentEvents(limit: Int = 100) throws -> [NetworkEvent] {
        try dbQueue.read { try NetworkEvent.order(sql: "created_at DESC, id DESC").limit(limit).fetchAll($0) }
    }

    public func observeRecentEvents(limit: Int = 100) -> AsyncValueObservation<[NetworkEvent]> {
        ValueObservation.tracking { try NetworkEvent.order(sql: "created_at DESC, id DESC").limit(limit).fetchAll($0) }.values(in: dbQueue)
    }

    // MARK: - Applying observations

    /// Matches a batch of observations to devices and records what changed.
    ///
    /// `isCoverageRun` says the batch is a complete look at the subnet (a
    /// finished scan, a router's whole ARP table): devices it didn't include
    /// were looked for and not found. A DHCP sync is not one — a lease says
    /// nothing about who is on the network.
    @discardableResult
    public func apply(
        _ observations: [HostObservation], toSubnet subnetID: Int64, isCoverageRun: Bool, now: Date = Date()
    ) throws -> NetworkApplyResult {
        try dbQueue.write { db in
            var context = try ApplyContext(db: db, subnetID: subnetID, now: now)
            let isFirstInventory = !context.devices.contains { $0.lastSeenAt != nil }
            context.isFirstInventory = isFirstInventory

            // MAC observations first, so an address-only record for the same
            // address is folded into the MAC device rather than kept apart.
            let ordered = observations.filter { $0.mac != nil } + observations.filter { $0.mac == nil }
            for observation in ordered {
                try context.apply(observation)
            }
            try context.flagConflictsWithinBatch(observations)
            if isCoverageRun {
                try context.markMissing()
            }
            return NetworkApplyResult(events: context.events, isFirstInventory: isFirstInventory)
        }
    }

    /// The working state of one `apply` call.
    private struct ApplyContext {
        let db: Database
        let subnetID: Int64
        let now: Date
        var devices: [NetworkDevice]
        var seen: Set<Int64> = []
        var events: [NetworkEvent] = []
        var isFirstInventory = false

        init(db: Database, subnetID: Int64, now: Date) throws {
            self.db = db
            self.subnetID = subnetID
            self.now = now
            devices = try NetworkDevice.filter(sql: "subnet_id = ?", arguments: [subnetID]).fetchAll(db)
        }

        mutating func apply(_ observation: HostObservation) throws {
            let ip = observation.ip.description
            let index = try deviceIndex(for: observation)
            var device = devices[index]
            let proves = observation.source.provesPresence

            if let hostname = observation.hostname, let source = observation.hostnameSource,
               source.hostnameRank >= (device.hostnameSource?.hostnameRank ?? 0) {
                device.hostname = hostname
                device.hostnameSource = source
            }
            if device.vendor == nil, let mac = observation.mac {
                device.vendor = OUIDatabase.shared.vendor(for: mac)
            }
            if let vlan = observation.vlanID { device.vlanID = vlan }
            if let port = observation.switchPort { device.switchPort = port }
            if let type = observation.deviceType, device.deviceType == .unknown { device.deviceType = type }

            if proves {
                if device.lastSeenAt == nil {
                    // Marked, so the starting inventory isn't shown as new.
                    record(.discovered, device: device, ip: ip, detail: isFirstInventory ? NetworkEvent.firstInventory : nil)
                } else if device.state == .offline {
                    record(.online, device: device, ip: ip)
                }
                device.state = .online
                device.missedScans = 0
                device.lastSeenAt = now
                seen.insert(device.id!)
            }

            // A lease gives a device an address only while nothing better
            // knows where it is, and never takes one from a device seen with it.
            if proves || device.currentIP == nil {
                if device.currentIP != ip {
                    if let previous = device.currentIP {
                        record(.ipChanged, device: device, ip: ip, detail: previous)
                    }
                    device.currentIP = ip
                    if proves { try releaseAddress(ip, to: &device) }
                }
                try touchHistory(deviceID: device.id!, ip: ip)
            }
            devices[index] = device
            try device.update(db)

            var sighting = NetworkSighting(
                deviceID: device.id!, source: observation.source, sourceID: observation.sourceID ?? 0, ip: ip,
                firstSeenAt: now, lastSeenAt: now
            )
            if let existing = try NetworkSighting.fetchOne(db, key: [
                "device_id": sighting.deviceID, "source": sighting.source.rawValue, "source_id": sighting.sourceID, "ip": ip,
            ]) {
                sighting.firstSeenAt = existing.firstSeenAt
            }
            try sighting.save(db)
        }

        /// The device an observation belongs to, created if there is none.
        private mutating func deviceIndex(for observation: HostObservation) throws -> Int {
            let ip = observation.ip.description
            if let mac = observation.mac?.description {
                if let index = devices.firstIndex(where: { $0.mac == mac }) { return index }
                // The address-only record for this address is this device
                // seen from further away: give it the MAC rather than keep two.
                if let index = devices.firstIndex(where: { $0.mac == nil && $0.currentIP == ip }) {
                    devices[index].mac = mac
                    return index
                }
                return try create(mac: mac)
            }
            if let index = devices.firstIndex(where: { $0.currentIP == ip && $0.mac != nil }) { return index }
            if let index = devices.firstIndex(where: { $0.currentIP == ip }) { return index }
            return try create(mac: nil)
        }

        /// Created without an address: `apply` then gives it one through the
        /// same path as a device that moved, which settles who held it before.
        private mutating func create(mac: String?) throws -> Int {
            var device = NetworkDevice(subnetID: subnetID, mac: mac, currentIP: nil, firstSeenAt: now)
            try device.insert(db)
            devices.append(device)
            return devices.count - 1
        }

        /// `device` now holds `ip`; whoever held it before lets go.
        private mutating func releaseAddress(_ ip: String, to device: inout NetworkDevice) throws {
            guard let index = devices.firstIndex(where: { $0.id != device.id && $0.currentIP == ip }) else { return }
            let previous = devices[index]
            if previous.mac == nil {
                // An address-only record has nothing but the address; it was
                // this device all along.
                try NetworkRepository.merge(previous.id!, into: device.id!, db: db)
                devices.remove(at: index)
                if let refreshed = try NetworkDevice.fetchOne(db, key: device.id!) {
                    device.displayName = refreshed.displayName
                    device.notes = refreshed.notes
                    device.deviceType = refreshed.deviceType
                    device.isWatched = refreshed.isWatched
                    device.ignoreConflicts = refreshed.ignoreConflicts
                    device.firstSeenAt = refreshed.firstSeenAt
                }
                return
            }
            devices[index].currentIP = nil
            try devices[index].update(db)
            record(.ipOwnerChanged, device: device, ip: ip, detail: String(previous.id!))

            // Back and forth: the address went from this device to the other
            // a moment ago, and now it's back. That's two devices on one IP.
            let since = now.addingTimeInterval(-NetworkRepository.conflictWindow)
            let bounced = try NetworkEvent.filter(
                sql: "kind = ? AND ip = ? AND device_id = ? AND detail = ? AND created_at >= ?",
                arguments: [NetworkEventKind.ipOwnerChanged.rawValue, ip, previous.id!, String(device.id!), since]
            ).fetchCount(db) > 0
            if bounced, !device.ignoreConflicts, !previous.ignoreConflicts {
                record(.conflict, device: device, ip: ip, detail: String(previous.id!))
            }
        }

        private func touchHistory(deviceID: Int64, ip: String) throws {
            if var latest = try NetworkIPHistoryEntry.filter(sql: "device_id = ?", arguments: [deviceID])
                .order(sql: "last_seen_at DESC, id DESC").fetchOne(db), latest.ip == ip {
                latest.lastSeenAt = now
                try latest.update(db)
            } else {
                var entry = NetworkIPHistoryEntry(deviceID: deviceID, ip: ip, firstSeenAt: now, lastSeenAt: now)
                try entry.insert(db)
            }
        }

        /// Two sources in one batch putting one address on two MACs at once.
        mutating func flagConflictsWithinBatch(_ observations: [HostObservation]) throws {
            let present = observations.filter { $0.source.provesPresence && $0.mac != nil }
            for (ip, group) in Dictionary(grouping: present, by: \.ip) {
                let macs = Set(group.compactMap { $0.mac?.description })
                guard macs.count > 1 else { continue }
                let involved = devices.filter { $0.mac.map(macs.contains) ?? false }
                guard !involved.contains(where: \.ignoreConflicts), let first = involved.first else { continue }
                record(.conflict, device: first, ip: ip.description, detail: involved.dropFirst().compactMap { $0.id.map(String.init) }.joined(separator: ","))
            }
        }

        /// Counts a miss against every device this complete run didn't see.
        mutating func markMissing() throws {
            for index in devices.indices {
                var device = devices[index]
                guard let id = device.id, !seen.contains(id), !device.isIgnored, device.state == .online else { continue }
                device.missedScans += 1
                if device.missedScans >= NetworkRepository.offlineAfterMissedScans {
                    device.state = .offline
                    record(.offline, device: device, ip: device.currentIP)
                }
                devices[index] = device
                try device.update(db)
            }
        }

        private mutating func record(_ kind: NetworkEventKind, device: NetworkDevice, ip: String?, detail: String? = nil) {
            var event = NetworkEvent(deviceID: device.id, subnetID: subnetID, kind: kind, ip: ip, detail: detail, createdAt: now)
            do {
                try event.insert(db)
                events.append(event)
            } catch {
                // An event that couldn't be stored is dropped, not the batch.
            }
        }
    }

    /// Where devices are on the switches: the VLAN a MAC was learned in, and
    /// its access port. Only devices already known by MAC are updated; a
    /// switch knows no addresses, so it can't add a device by itself.
    public func updateSwitchLocations(vlans: [MACAddress: Int], ports: [MACAddress: String], switchName: String) throws {
        guard !vlans.isEmpty || !ports.isEmpty else { return }
        try dbQueue.write { db in
            for var device in try NetworkDevice.filter(sql: "mac IS NOT NULL").fetchAll(db) {
                guard let mac = device.macAddress else { continue }
                let vlan = vlans[mac]
                let port = ports[mac]
                guard vlan != nil || port != nil else { continue }
                if let vlan { device.vlanID = vlan }
                if let port {
                    device.switchPort = port
                    device.switchName = switchName
                }
                try device.update(db)
            }
        }
    }

    // MARK: - Scans

    public func beginScan(subnetID: Int64, trigger: String, now: Date = Date()) throws -> NetworkScan {
        try dbQueue.write { db in
            var scan = NetworkScan(subnetID: subnetID, trigger: trigger, mode: nil, status: .running, startedAt: now,
                                   finishedAt: nil, hostsProbed: 0, hostsFound: 0)
            try scan.insert(db)
            return scan
        }
    }

    public func finishScan(_ scan: NetworkScan, status: NetworkScanStatus, outcome: SubnetScanOutcome?, now: Date = Date()) throws {
        try dbQueue.write { db in
            var finished = scan
            finished.status = status
            finished.finishedAt = now
            finished.mode = outcome?.mode
            finished.hostsProbed = outcome?.probedCount ?? 0
            finished.hostsFound = outcome?.observations.count ?? 0
            try finished.update(db)
            try db.execute(
                sql: "UPDATE network_subnets SET last_scan_at = ?, last_scan_status = ?, last_scan_mode = ? WHERE id = ?",
                arguments: [now, status.rawValue, outcome?.mode.rawValue, scan.subnetID]
            )
        }
    }

    public func observeRunningScans() -> AsyncValueObservation<[NetworkScan]> {
        ValueObservation.tracking { try NetworkScan.filter(sql: "status = 'running'").fetchAll($0) }.values(in: dbQueue)
    }

    /// Scans left `running` by a quit or a crash.
    public func closeAbandonedScans(now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE network_scans SET status = 'cancelled', finished_at = ? WHERE status = 'running'", arguments: [now])
        }
    }

    // MARK: - Sources

    public func sources() throws -> [NetworkSource] {
        try dbQueue.read { try NetworkSource.order(sql: "name COLLATE NOCASE").fetchAll($0) }
    }

    public func observeSources() -> AsyncValueObservation<[NetworkSource]> {
        ValueObservation.tracking { try NetworkSource.order(sql: "name COLLATE NOCASE").fetchAll($0) }.values(in: dbQueue)
    }

    public func source(id: Int64) throws -> NetworkSource? {
        try dbQueue.read { try NetworkSource.fetchOne($0, key: id) }
    }

    @discardableResult
    public func save(_ source: NetworkSource) throws -> NetworkSource {
        var saved = source
        try dbQueue.write { try saved.save($0) }
        return saved
    }

    public func deleteSource(id: Int64) throws {
        _ = try dbQueue.write { try NetworkSource.deleteOne($0, key: id) }
    }

    /// Records the outcome of a poll. Returns the event to alert on when the
    /// source has just crossed into failing (third failure in a row) or come
    /// back from it.
    public func recordPoll(sourceID: Int64, error: String?, system: SNMPSystemInfo? = nil, now: Date = Date()) throws -> NetworkEvent? {
        try dbQueue.write { db in
            guard var source = try NetworkSource.fetchOne(db, key: sourceID) else { return nil }
            let wasFailing = source.consecutiveFailures >= NetworkRepository.offlineAfterMissedScans
            source.lastPollAt = now
            var event: NetworkEvent?
            if let error {
                source.consecutiveFailures += 1
                source.lastError = error
                if source.consecutiveFailures == NetworkRepository.offlineAfterMissedScans {
                    event = NetworkEvent(sourceID: sourceID, kind: .sourceFailed, detail: error, createdAt: now)
                }
            } else {
                source.consecutiveFailures = 0
                source.lastError = nil
                source.lastSuccessAt = now
                if let system {
                    source.sysName = system.name
                    source.sysDescr = system.description
                }
                if wasFailing { event = NetworkEvent(sourceID: sourceID, kind: .sourceRecovered, createdAt: now) }
            }
            try source.update(db)
            if var stored = event {
                try stored.insert(db)
                return stored
            }
            return nil
        }
    }

    public func setTLSFingerprint(_ fingerprint: String?, sourceID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE network_sources SET tls_fingerprint = ? WHERE id = ?", arguments: [fingerprint, sourceID])
        }
    }

    // MARK: - DHCP leases

    public func replaceLeases(_ leases: [DHCPLease], sourceID: Int64, now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM network_dhcp_leases WHERE source_id = ?", arguments: [sourceID])
            for lease in leases {
                try NetworkDHCPLease(
                    sourceID: sourceID, ip: lease.ip.description, mac: lease.mac.description, hostname: lease.hostname,
                    endsAt: lease.endsAt, isActive: lease.isActive, isReserved: lease.isReserved, syncedAt: now
                ).insert(db)
            }
        }
    }

    public func leases() throws -> [NetworkDHCPLease] {
        try dbQueue.read { try NetworkDHCPLease.fetchAll($0) }
    }

    public func observeLeases() -> AsyncValueObservation<[NetworkDHCPLease]> {
        ValueObservation.tracking { try NetworkDHCPLease.fetchAll($0) }.values(in: dbQueue)
    }

    // MARK: - SNMP interfaces

    /// Stores the latest counters and, from the previous reading, the rates.
    /// A counter that went backwards (the device restarted, or a 32-bit
    /// counter wrapped) gives no rate for that round rather than a wrong one.
    public func recordInterfaces(_ readings: [SNMPInterfaceReading], sourceID: Int64, now: Date = Date()) throws {
        try dbQueue.write { db in
            let previous = Dictionary(
                uniqueKeysWithValues: try NetworkSNMPInterface.filter(sql: "source_id = ?", arguments: [sourceID]).fetchAll(db)
                    .map { ($0.ifIndex, $0) }
            )
            try db.execute(sql: "DELETE FROM network_snmp_interfaces WHERE source_id = ?", arguments: [sourceID])
            for reading in readings {
                let inOctets = reading.inOctets.map { Int64(bitPattern: $0) }
                let outOctets = reading.outOctets.map { Int64(bitPattern: $0) }
                var row = NetworkSNMPInterface(
                    sourceID: sourceID, ifIndex: reading.index, name: reading.name, alias: reading.alias,
                    operStatus: reading.operStatus, speedMbps: reading.speedMbps, inOctets: inOctets, outOctets: outOctets,
                    inBps: nil, outBps: nil, sampledAt: now
                )
                if let before = previous[reading.index] {
                    let seconds = now.timeIntervalSince(before.sampledAt)
                    row.inBps = Self.rate(from: before.inOctets, to: inOctets, seconds: seconds)
                    row.outBps = Self.rate(from: before.outOctets, to: outOctets, seconds: seconds)
                }
                try row.insert(db)
                if let inBps = row.inBps, let outBps = row.outBps {
                    try NetworkSNMPSample(sourceID: sourceID, ifIndex: reading.index, inBps: inBps, outBps: outBps, sampledAt: now).insert(db)
                }
            }
        }
    }

    static func rate(from old: Int64?, to new: Int64?, seconds: TimeInterval) -> Double? {
        guard let old, let new, seconds >= 1 else { return nil }
        let before = UInt64(bitPattern: old)
        let after = UInt64(bitPattern: new)
        guard after >= before else { return nil }
        return Double(after - before) * 8 / seconds
    }

    public func interfaces(sourceID: Int64) throws -> [NetworkSNMPInterface] {
        try dbQueue.read {
            try NetworkSNMPInterface.filter(sql: "source_id = ?", arguments: [sourceID]).order(sql: "if_index").fetchAll($0)
        }
    }

    public func samples(sourceID: Int64, ifIndex: Int, since: Date) throws -> [NetworkSNMPSample] {
        try dbQueue.read {
            try NetworkSNMPSample.filter(sql: "source_id = ? AND if_index = ? AND sampled_at >= ?", arguments: [sourceID, ifIndex, since])
                .order(sql: "sampled_at").fetchAll($0)
        }
    }

    // MARK: - Ports

    public func portResults(deviceID: Int64) throws -> [NetworkPortResult] {
        try dbQueue.read {
            try NetworkPortResult.filter(sql: "device_id = ?", arguments: [deviceID]).order(sql: "port").fetchAll($0)
        }
    }

    /// Stores a port scan and records ports that opened or closed since the
    /// previous one. The first scan of a device sets the baseline silently.
    @discardableResult
    public func recordPortScan(deviceID: Int64, results: [(port: Int, state: TCPPortState, latencyMs: Double?)], now: Date = Date()) throws -> [NetworkEvent] {
        try dbQueue.write { db in
            let previous = Dictionary(
                uniqueKeysWithValues: try NetworkPortResult.filter(sql: "device_id = ?", arguments: [deviceID]).fetchAll(db).map { ($0.port, $0.state) }
            )
            let ip = try String.fetchOne(db, sql: "SELECT current_ip FROM network_devices WHERE id = ?", arguments: [deviceID])
            var events: [NetworkEvent] = []
            for result in results {
                try NetworkPortResult(deviceID: deviceID, port: result.port, state: result.state, latencyMs: result.latencyMs, scannedAt: now).save(db)
                guard let before = previous[result.port], before != result.state else { continue }
                if result.state == .open || before == .open {
                    var event = NetworkEvent(deviceID: deviceID, kind: result.state == .open ? .portOpened : .portClosed,
                                             ip: ip, detail: String(result.port), createdAt: now)
                    try event.insert(db)
                    events.append(event)
                }
            }
            return events
        }
    }

    // MARK: - Menu bar

    public struct Summary: Equatable, Sendable {
        public var devices = 0
        public var online = 0
        public var newRecently = 0
        public var conflictsRecently = 0
        public var watchedOffline = 0

        public init(devices: Int = 0, online: Int = 0, newRecently: Int = 0, conflictsRecently: Int = 0, watchedOffline: Int = 0) {
            self.devices = devices
            self.online = online
            self.newRecently = newRecently
            self.conflictsRecently = conflictsRecently
            self.watchedOffline = watchedOffline
        }
    }

    /// The counts the menu bar shows, in one read. "Recently" is since `since`.
    public func summary(since: Date) throws -> Summary {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM network_devices WHERE is_ignored = 0),
                    (SELECT COUNT(*) FROM network_devices WHERE is_ignored = 0 AND state = 'online'),
                    (SELECT COUNT(DISTINCT device_id) FROM network_events
                        WHERE kind = 'discovered' AND detail IS NOT 'first_inventory' AND created_at >= ?),
                    (SELECT COUNT(DISTINCT ip) FROM network_events WHERE kind = 'conflict' AND created_at >= ?),
                    (SELECT COUNT(*) FROM network_devices WHERE is_ignored = 0 AND is_watched = 1 AND state = 'offline')
                """, arguments: [since, since])
            guard let row else { return Summary() }
            return Summary(devices: row[0], online: row[1], newRecently: row[2], conflictsRecently: row[3], watchedOffline: row[4])
        }
    }

    // MARK: - Alerts bookkeeping

    /// Whether an alert of `kind` for this device is due, given the last one
    /// sent: at most one per kind per device per `cooldown`.
    public func claimAlert(deviceID: Int64, kind: NetworkEventKind, cooldown: TimeInterval = 3_600, now: Date = Date()) throws -> Bool {
        try dbQueue.write { db in
            guard var device = try NetworkDevice.fetchOne(db, key: deviceID) else { return false }
            if device.lastAlertKind == kind.rawValue, let last = device.lastAlertSentAt, now.timeIntervalSince(last) < cooldown {
                return false
            }
            device.lastAlertKind = kind.rawValue
            device.lastAlertSentAt = now
            try device.update(db)
            return true
        }
    }

    // MARK: - Housekeeping

    public static let scanRetentionDays = 30
    public static let eventRetentionDays = 365
    public static let sampleRetentionDays = 7

    public func cleanUp(now: Date = Date()) throws {
        try dbQueue.write { db in
            func cutoff(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
            try db.execute(sql: "DELETE FROM network_scans WHERE started_at < ?", arguments: [cutoff(Self.scanRetentionDays)])
            try db.execute(sql: "DELETE FROM network_events WHERE created_at < ?", arguments: [cutoff(Self.eventRetentionDays)])
            try db.execute(sql: "DELETE FROM network_snmp_samples WHERE sampled_at < ?", arguments: [cutoff(Self.sampleRetentionDays)])
        }
    }

    /// Everything the Network feature stored, and nothing else. Returns the
    /// Keychain references of the deleted sources so their secrets can go too.
    public func deleteAll() throws -> [String] {
        try dbQueue.write { db in
            let refs = try String.fetchAll(db, sql: "SELECT keychain_ref FROM network_sources")
            // Allowlist entries a DHCP source added for its lease file.
            try db.execute(sql: "DELETE FROM remote_server_allowlist WHERE kind = ?", arguments: [RemoteAllowlistKind.dhcpLeaseFile.rawValue])
            for table in ["network_port_results", "network_snmp_samples", "network_snmp_interfaces", "network_dhcp_leases",
                          "network_scans", "network_events", "network_sightings", "network_ip_history", "network_devices",
                          "network_sources", "network_subnets"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            return refs
        }
    }
}
