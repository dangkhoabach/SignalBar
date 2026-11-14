import Foundation
import GRDB

/// The Keychain side of a Network source: its community, SNMPv3 passwords
/// or router password, under its own service so they never mix with SSH keys.
public struct NetworkSourceSecrets: Sendable {
    let keychain: KeychainStoring

    public init(keychain: KeychainStoring = KeychainStore(service: KeychainStore.networkService)) {
        self.keychain = keychain
    }

    public func store(_ value: String, kind: KeychainSecretKind, ref: String) throws {
        if value.isEmpty {
            try keychain.delete(ref: ref, kind: kind)
        } else {
            try keychain.set(ref: ref, kind: kind, data: Data(value.utf8))
        }
    }

    public func read(_ kind: KeychainSecretKind, ref: String) -> String? {
        (try? keychain.readForStatusCheck(ref: ref, kind: kind)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func deleteAll(ref: String) {
        for kind in KeychainSecretKind.networkKinds {
            try? keychain.delete(ref: ref, kind: kind)
        }
    }

    public func snmpCredentials(for source: NetworkSource) -> SNMPCredentials {
        if source.snmpVersion == .v3 {
            return .v3(
                user: source.username ?? "", auth: source.authProtocol,
                authPassword: read(.snmpAuthPassword, ref: source.keychainRef) ?? "",
                priv: source.privProtocol, privPassword: read(.snmpPrivPassword, ref: source.keychainRef) ?? ""
            )
        }
        return .v2c(community: read(.snmpCommunity, ref: source.keychainRef) ?? "")
    }
}

public enum NetworkSourceError: Error, Equatable, Sendable {
    case missingServer
    case missingLeaseFile
    case commandFailed(String)
}

extension NetworkSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingServer: "The server this source reads from was removed from the Server Manager."
        case .missingLeaseFile: "No lease file is set for this source."
        case .commandFailed(let message): message
        }
    }
}

/// Reads one source and folds what it says into the inventory.
public struct NetworkSourcePoller: Sendable {
    let repo: NetworkRepository
    let secrets: NetworkSourceSecrets
    let remoteRepo: RemoteServerRepository

    public init(dbQueue: DatabaseQueue, secrets: NetworkSourceSecrets = NetworkSourceSecrets(), remoteKeychain: KeychainStoring = KeychainStore()) {
        self.repo = NetworkRepository(dbQueue: dbQueue)
        self.secrets = secrets
        self.remoteRepo = RemoteServerRepository(dbQueue: dbQueue, keychain: remoteKeychain)
    }

    /// What a poll changed, per subnet, plus the source's own state change.
    public struct Outcome: Sendable {
        public var results: [(subnetID: Int64, result: NetworkApplyResult)] = []
        public var sourceEvent: NetworkEvent?
        public var error: String?
    }

    public func poll(_ source: NetworkSource, now: Date = Date()) async -> Outcome {
        guard let id = source.id else { return Outcome() }
        var outcome = Outcome()
        do {
            switch source.kind {
            case .snmp:
                let client = SNMPClient(host: source.host, port: UInt16(clamping: source.port), credentials: secrets.snmpCredentials(for: source))
                let snapshot = try await SNMPCollector.collect(client, roles: source.snmpRoles)
                outcome.results = try applySNMP(snapshot, source: source, sourceID: id, now: now)
                outcome.sourceEvent = try repo.recordPoll(sourceID: id, error: nil, system: snapshot.system, now: now)
            case .dhcpSSH, .dhcpMikroTik:
                let leases = try await fetchLeases(source, sourceID: id, now: now)
                outcome.results = try applyLeases(leases, sourceID: id, now: now)
                outcome.sourceEvent = try repo.recordPoll(sourceID: id, error: nil, now: now)
            case .dhcpImport:
                return outcome
            }
        } catch {
            outcome.error = error.localizedDescription
            outcome.sourceEvent = try? repo.recordPoll(sourceID: id, error: error.localizedDescription, now: now)
        }
        return outcome
    }

    /// Checks a source answers without storing anything: the device's name
    /// for SNMP, the number of leases for DHCP.
    public func test(_ source: NetworkSource) async throws -> String {
        switch source.kind {
        case .snmp:
            let client = SNMPClient(host: source.host, port: UInt16(clamping: source.port), credentials: secrets.snmpCredentials(for: source))
            let system = try await SNMPCollector.system(client)
            return [system.name, system.description].compactMap { $0 }.joined(separator: " — ")
        case .dhcpSSH, .dhcpMikroTik:
            let leases = try await fetchLeases(source, sourceID: source.id, now: Date())
            return String(leases.filter(\.isActive).count)
        case .dhcpImport:
            return ""
        }
    }

    /// The subnets an SNMP device has addresses in, for the user to add.
    public func detectSubnets(_ source: NetworkSource) async throws -> [IPv4CIDR] {
        let client = SNMPClient(host: source.host, port: UInt16(clamping: source.port), credentials: secrets.snmpCredentials(for: source))
        return SNMPCollector.parseNetworks(try await client.walk(SNMPCollector.Objects.ipAdEntNetMask))
    }

    /// Replaces an import source's leases with the contents of a file.
    public func importLeases(_ text: String, format: DHCPLeaseFormat, sourceID: Int64, now: Date = Date()) throws -> Int {
        let leases = DHCPLeaseParser.parse(text, format: format, now: now)
        _ = try applyLeases(leases, sourceID: sourceID, now: now)
        _ = try repo.recordPoll(sourceID: sourceID, error: nil, now: now)
        return leases.count
    }

    // MARK: -

    private func fetchLeases(_ source: NetworkSource, sourceID: Int64?, now: Date) async throws -> [DHCPLease] {
        switch source.kind {
        case .dhcpSSH:
            guard let serverID = source.remoteServerID, let server = try remoteRepo.get(id: serverID) else {
                throw NetworkSourceError.missingServer
            }
            guard let path = source.leasePath, !path.isEmpty else { throw NetworkSourceError.missingLeaseFile }
            let result = try await RemoteCommandExecutor(repo: remoteRepo).execute(.readDHCPLeases(path: path), on: server)
            guard result.succeeded else {
                throw NetworkSourceError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return DHCPLeaseParser.parse(result.stdout, format: source.leaseFormat ?? .dnsmasq, now: now)
        case .dhcpMikroTik:
            let fetched = try await MikroTikLeaseClient.fetch(
                host: source.host, port: source.port, username: source.username ?? "",
                password: secrets.read(.routerPassword, ref: source.keychainRef) ?? "",
                pinnedFingerprint: source.tlsFingerprint, now: now
            )
            if source.tlsFingerprint == nil, let fingerprint = fetched.fingerprint, let sourceID {
                try repo.setTLSFingerprint(fingerprint, sourceID: sourceID)
            }
            return fetched.leases
        case .snmp, .dhcpImport:
            return []
        }
    }

    private func applyLeases(_ leases: [DHCPLease], sourceID: Int64, now: Date) throws -> [(subnetID: Int64, result: NetworkApplyResult)] {
        try repo.replaceLeases(leases, sourceID: sourceID, now: now)
        let observations = leases.filter { $0.isActive || $0.isReserved }.map {
            HostObservation(ip: $0.ip, mac: $0.mac, source: .dhcp, sourceID: sourceID, hostname: $0.hostname, hostnameSource: .dhcp)
        }
        return try applyBySubnet(observations, isCoverageRun: false, now: now)
    }

    private func applySNMP(
        _ snapshot: SNMPSnapshot, source: NetworkSource, sourceID: Int64, now: Date
    ) throws -> [(subnetID: Int64, result: NetworkApplyResult)] {
        let names = Dictionary(uniqueKeysWithValues: snapshot.interfaces.map { ($0.index, $0.name) })
        if source.snmpRoles.contains(.interfaces) {
            try repo.recordInterfaces(snapshot.interfaces, sourceID: sourceID, now: now)
        }
        if source.snmpRoles.contains(.macTable) {
            var vlans: [MACAddress: Int] = [:]
            for entry in snapshot.macTable { if let vlan = entry.vlanID { vlans[entry.mac] = vlan } }
            let ports = SNMPCollector.accessPorts(snapshot.macTable).compactMapValues { entry in
                entry.interfaceIndex.flatMap { names[$0] ?? String($0) }
            }
            try repo.updateSwitchLocations(vlans: vlans, ports: ports, switchName: snapshot.system.name ?? source.name)
        }
        guard source.snmpRoles.contains(.arpTable) else { return [] }
        let observations = snapshot.arp.map {
            HostObservation(ip: $0.ip, mac: $0.mac, source: .arpSNMP, sourceID: sourceID)
        }
        return try applyBySubnet(observations, isCoverageRun: true, now: now)
    }

    /// Files each observation under the configured subnet holding its
    /// address; anything outside every subnet is ignored.
    private func applyBySubnet(
        _ observations: [HostObservation], isCoverageRun: Bool, now: Date
    ) throws -> [(subnetID: Int64, result: NetworkApplyResult)] {
        let subnets = try repo.subnets().compactMap { subnet in subnet.network.map { (subnet, $0) } }
        var grouped: [Int64: [HostObservation]] = [:]
        for observation in observations {
            guard let (subnet, _) = subnets.first(where: { $0.1.contains(observation.ip) }), let id = subnet.id else { continue }
            grouped[id, default: []].append(observation)
        }
        return try grouped.map { subnetID, batch in
            (subnetID, try repo.apply(batch, toSubnet: subnetID, isCoverageRun: isCoverageRun, now: now))
        }
    }
}
