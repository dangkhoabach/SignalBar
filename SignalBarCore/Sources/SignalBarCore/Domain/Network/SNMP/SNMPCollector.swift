import Foundation

public struct SNMPSystemInfo: Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var uptimeTicks: UInt64?
}

public struct SNMPInterfaceReading: Sendable, Equatable {
    public var index: Int
    public var name: String
    public var alias: String?
    /// ifOperStatus: 1 up, 2 down, others testing/unknown/dormant…
    public var operStatus: Int?
    public var speedMbps: Int?
    public var inOctets: UInt64?
    public var outOctets: UInt64?
    /// Whether the counters are the 64-bit ifHC ones; the 32-bit fallback
    /// wraps every few seconds on a busy gigabit link.
    public var hasHighCapacityCounters: Bool
}

public struct SNMPARPEntry: Sendable, Equatable {
    public var ip: IPv4Address
    public var mac: MACAddress
    public var interfaceIndex: Int
}

public struct SNMPMACTableEntry: Sendable, Equatable {
    public var mac: MACAddress
    /// The forwarding database the MAC was learned in, which on almost every
    /// switch is the VLAN ID. `nil` from a switch without 802.1Q tables.
    public var vlanID: Int?
    public var interfaceIndex: Int?
}

public struct SNMPSnapshot: Sendable, Equatable {
    public var system: SNMPSystemInfo
    public var interfaces: [SNMPInterfaceReading] = []
    public var arp: [SNMPARPEntry] = []
    public var macTable: [SNMPMACTableEntry] = []
    /// The subnets the device has an address in — the VLANs it routes.
    public var networks: [IPv4CIDR] = []
}

public struct SNMPRoles: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A router or L3 switch: its ARP table maps IP to MAC for every VLAN it routes.
    public static let arpTable = SNMPRoles(rawValue: 1)
    /// A switch: its MAC address table says which VLAN and port a MAC is on.
    public static let macTable = SNMPRoles(rawValue: 2)
    /// Interface status and traffic.
    public static let interfaces = SNMPRoles(rawValue: 4)
}

/// Reads what the Network feature uses from one device: standard MIB-2
/// objects only, so it works across vendors.
public enum SNMPCollector {
    enum Objects {
        static let sysDescr: OID = "1.3.6.1.2.1.1.1.0"
        static let sysUpTime: OID = "1.3.6.1.2.1.1.3.0"
        static let sysName: OID = "1.3.6.1.2.1.1.5.0"
        static let ifDescr: OID = "1.3.6.1.2.1.2.2.1.2"
        static let ifOperStatus: OID = "1.3.6.1.2.1.2.2.1.8"
        static let ifInOctets: OID = "1.3.6.1.2.1.2.2.1.10"
        static let ifOutOctets: OID = "1.3.6.1.2.1.2.2.1.16"
        static let ifName: OID = "1.3.6.1.2.1.31.1.1.1.1"
        static let ifHCInOctets: OID = "1.3.6.1.2.1.31.1.1.1.6"
        static let ifHCOutOctets: OID = "1.3.6.1.2.1.31.1.1.1.10"
        static let ifHighSpeed: OID = "1.3.6.1.2.1.31.1.1.1.15"
        static let ifAlias: OID = "1.3.6.1.2.1.31.1.1.1.18"
        static let ipAdEntNetMask: OID = "1.3.6.1.2.1.4.20.1.3"
        static let ipNetToPhysicalPhysAddress: OID = "1.3.6.1.2.1.4.35.1.4"
        static let ipNetToMediaPhysAddress: OID = "1.3.6.1.2.1.4.22.1.2"
        static let dot1dBasePortIfIndex: OID = "1.3.6.1.2.1.17.1.4.1.2"
        static let dot1dTpFdbPort: OID = "1.3.6.1.2.1.17.4.3.1.2"
        static let dot1qTpFdbPort: OID = "1.3.6.1.2.1.17.7.1.2.2.1.2"
    }

    public static func system(_ client: SNMPClient) async throws -> SNMPSystemInfo {
        let values = try await client.get([Objects.sysName, Objects.sysDescr, Objects.sysUpTime])
        func value(_ oid: OID) -> SNMPValue? { values.first { $0.oid == oid }?.value }
        return SNMPSystemInfo(
            name: value(Objects.sysName)?.text, description: value(Objects.sysDescr)?.text,
            uptimeTicks: value(Objects.sysUpTime)?.unsigned
        )
    }

    public static func collect(_ client: SNMPClient, roles: SNMPRoles) async throws -> SNMPSnapshot {
        var snapshot = SNMPSnapshot(system: try await system(client))
        // Interface names are needed for ports and VLAN interfaces whatever
        // the roles; counters only when traffic is watched.
        let names = try await interfaceNames(client)
        if roles.contains(.interfaces) {
            snapshot.interfaces = try await interfaces(client, names: names)
        } else {
            snapshot.interfaces = names.map {
                SNMPInterfaceReading(index: $0.key, name: $0.value, hasHighCapacityCounters: false)
            }.sorted { $0.index < $1.index }
        }
        if roles.contains(.arpTable) {
            var arp = parseARPPhysical(try await client.walk(Objects.ipNetToPhysicalPhysAddress))
            if arp.isEmpty { arp = parseARPMedia(try await client.walk(Objects.ipNetToMediaPhysAddress)) }
            snapshot.arp = arp
            snapshot.networks = parseNetworks(try await client.walk(Objects.ipAdEntNetMask))
        }
        if roles.contains(.macTable) {
            let basePorts = parseBasePorts(try await client.walk(Objects.dot1dBasePortIfIndex))
            var table = parseQBridgeFDB(try await client.walk(Objects.dot1qTpFdbPort), basePorts: basePorts)
            if table.isEmpty { table = parseBridgeFDB(try await client.walk(Objects.dot1dTpFdbPort), basePorts: basePorts) }
            snapshot.macTable = table
        }
        return snapshot
    }

    private static func interfaceNames(_ client: SNMPClient) async throws -> [Int: String] {
        var names = column(try await client.walk(Objects.ifName)) { $0.text }
        if names.isEmpty { names = column(try await client.walk(Objects.ifDescr)) { $0.text } }
        return names
    }

    private static func interfaces(_ client: SNMPClient, names: [Int: String]) async throws -> [SNMPInterfaceReading] {
        let status = column(try await client.walk(Objects.ifOperStatus)) { $0.unsigned.map(Int.init) }
        let speed = column(try await client.walk(Objects.ifHighSpeed)) { $0.unsigned.map(Int.init) }
        let alias = column(try await client.walk(Objects.ifAlias)) { $0.text }
        var inOctets = column(try await client.walk(Objects.ifHCInOctets)) { $0.unsigned }
        var outOctets = column(try await client.walk(Objects.ifHCOutOctets)) { $0.unsigned }
        let highCapacity = !inOctets.isEmpty
        if !highCapacity {
            inOctets = column(try await client.walk(Objects.ifInOctets)) { $0.unsigned }
            outOctets = column(try await client.walk(Objects.ifOutOctets)) { $0.unsigned }
        }
        return names.keys.sorted().map { index in
            SNMPInterfaceReading(
                index: index, name: names[index] ?? String(index), alias: alias[index], operStatus: status[index],
                speedMbps: speed[index], inOctets: inOctets[index], outOctets: outOctets[index],
                hasHighCapacityCounters: highCapacity
            )
        }
    }

    /// A table column keyed by its single-number row index (ifIndex, port).
    static func column<T>(_ rows: [SNMPVarBind], _ transform: (SNMPValue) -> T?) -> [Int: T] {
        var result: [Int: T] = [:]
        for row in rows {
            guard let last = row.oid.components.last, let value = transform(row.value) else { continue }
            result[Int(last)] = value
        }
        return result
    }

    /// ipNetToPhysicalTable, indexed `ifIndex.addressType.length.address`;
    /// only IPv4 rows (type 1, length 4).
    static func parseARPPhysical(_ rows: [SNMPVarBind]) -> [SNMPARPEntry] {
        rows.compactMap { row in
            let index = row.oid.suffix(after: Objects.ipNetToPhysicalPhysAddress)
            guard index.count == 7, index[1] == 1, index[2] == 4,
                  case .octets(let bytes) = row.value, let mac = MACAddress(bytes: bytes), !mac.isZero, !mac.isGroup
            else { return nil }
            return SNMPARPEntry(ip: address(index[3...]), mac: mac, interfaceIndex: Int(index[0]))
        }
    }

    /// The older ipNetToMediaTable, indexed `ifIndex.a.b.c.d`.
    static func parseARPMedia(_ rows: [SNMPVarBind]) -> [SNMPARPEntry] {
        rows.compactMap { row in
            let index = row.oid.suffix(after: Objects.ipNetToMediaPhysAddress)
            guard index.count == 5, case .octets(let bytes) = row.value,
                  let mac = MACAddress(bytes: bytes), !mac.isZero, !mac.isGroup
            else { return nil }
            return SNMPARPEntry(ip: address(index[1...]), mac: mac, interfaceIndex: Int(index[0]))
        }
    }

    /// ipAdEntNetMask, indexed by the device's own address.
    static func parseNetworks(_ rows: [SNMPVarBind]) -> [IPv4CIDR] {
        let networks = rows.compactMap { row -> IPv4CIDR? in
            let index = row.oid.suffix(after: Objects.ipAdEntNetMask)
            guard index.count == 4, case .ipAddress(let mask) = row.value,
                  let network = IPv4CIDR(address: address(index[...]), netmask: mask),
                  network.prefixLength >= NetworkRepository.largestPrefix, network.prefixLength <= 30, network.isManageable
            else { return nil }
            return network
        }
        return Array(Set(networks)).sorted { $0.network < $1.network }
    }

    static func parseBasePorts(_ rows: [SNMPVarBind]) -> [Int: Int] {
        column(rows) { $0.unsigned.map(Int.init) }
    }

    /// dot1qTpFdbPort, indexed `fdbId.m1.m2.m3.m4.m5.m6`, value a bridge port.
    static func parseQBridgeFDB(_ rows: [SNMPVarBind], basePorts: [Int: Int]) -> [SNMPMACTableEntry] {
        rows.compactMap { row in
            let index = row.oid.suffix(after: Objects.dot1qTpFdbPort)
            guard index.count == 7, let port = row.value.unsigned, port > 0,
                  let mac = MACAddress(bytes: index[1...].map { UInt8(truncatingIfNeeded: $0) }), !mac.isGroup
            else { return nil }
            return SNMPMACTableEntry(mac: mac, vlanID: Int(index[0]), interfaceIndex: basePorts[Int(port)] ?? Int(port))
        }
    }

    /// dot1dTpFdbPort, indexed by the six MAC bytes, no VLAN.
    static func parseBridgeFDB(_ rows: [SNMPVarBind], basePorts: [Int: Int]) -> [SNMPMACTableEntry] {
        rows.compactMap { row in
            let index = row.oid.suffix(after: Objects.dot1dTpFdbPort)
            guard index.count == 6, let port = row.value.unsigned, port > 0,
                  let mac = MACAddress(bytes: index.map { UInt8(truncatingIfNeeded: $0) }), !mac.isGroup
            else { return nil }
            return SNMPMACTableEntry(mac: mac, vlanID: nil, interfaceIndex: basePorts[Int(port)] ?? Int(port))
        }
    }

    private static func address(_ octets: ArraySlice<UInt32>) -> IPv4Address {
        IPv4Address(octets.reduce(0) { $0 << 8 | ($1 & 0xFF) })
    }

    /// Ports with this many MACs or more are uplinks or trunks to another
    /// switch, not where a device is plugged in.
    public static let uplinkMACThreshold = 4

    /// Each MAC's access port: the interface it was learned on, unless that
    /// interface carries so many MACs it must lead to another switch.
    public static func accessPorts(_ table: [SNMPMACTableEntry]) -> [MACAddress: SNMPMACTableEntry] {
        let perInterface = Dictionary(grouping: table.compactMap(\.interfaceIndex), by: { $0 }).mapValues(\.count)
        var result: [MACAddress: SNMPMACTableEntry] = [:]
        for entry in table {
            guard let interface = entry.interfaceIndex, perInterface[interface, default: 0] < uplinkMACThreshold else { continue }
            result[entry.mac] = entry
        }
        return result
    }
}
