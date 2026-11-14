import Foundation
import GRDB

/// A subnet the user manages. Only subnets listed here are ever scanned, and
/// a device is always filed under the subnet holding its address.
public struct NetworkSubnet: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    /// Canonical `a.b.c.d/n`.
    public var cidr: String
    public var vlanID: Int?
    public var notes: String?
    /// Whether this Mac probes the subnet itself. Off for a subnet known
    /// only through SNMP or DHCP, or one whose switches police ARP.
    public var scanEnabled: Bool
    public var scanIntervalSecs: Int
    public var lastScanAt: Date?
    public var lastScanStatus: NetworkScanStatus?
    public var lastScanMode: SubnetScanMode?
    public var createdAt: Date

    public init(
        id: Int64? = nil, name: String, cidr: String, vlanID: Int? = nil, notes: String? = nil,
        scanEnabled: Bool = true, scanIntervalSecs: Int = 900, lastScanAt: Date? = nil,
        lastScanStatus: NetworkScanStatus? = nil, lastScanMode: SubnetScanMode? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cidr = cidr
        self.vlanID = vlanID
        self.notes = notes
        self.scanEnabled = scanEnabled
        self.scanIntervalSecs = scanIntervalSecs
        self.lastScanAt = lastScanAt
        self.lastScanStatus = lastScanStatus
        self.lastScanMode = lastScanMode
        self.createdAt = createdAt
    }

    public var network: IPv4CIDR? { IPv4CIDR(cidr) }
}

extension NetworkSubnet: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_subnets"

    enum CodingKeys: String, CodingKey {
        case id, name, cidr, notes
        case vlanID = "vlan_id"
        case scanEnabled = "scan_enabled"
        case scanIntervalSecs = "scan_interval_secs"
        case lastScanAt = "last_scan_at"
        case lastScanStatus = "last_scan_status"
        case lastScanMode = "last_scan_mode"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum NetworkScanStatus: String, Codable, Sendable {
    case running, completed, cancelled, failed
    case localNetworkDenied = "local_network_denied"
    case noRoute = "no_route"
}

public enum NetworkDeviceState: String, Codable, Sendable, CaseIterable {
    /// Seen by a source that proves presence, at its last run.
    case online
    /// Missed three runs in a row after having been online.
    case offline
    /// Only known from a lease or by hand; never seen on the network.
    case unknown
}

public enum NetworkDeviceType: String, Codable, Sendable, CaseIterable {
    case unknown, router
    case networkSwitch = "switch"
    case accessPoint = "access_point"
    case computer, server, phone, tablet, printer, tv, camera, iot, other
}

/// A device in the inventory. Identified by its MAC within a subnet when one
/// is known; a device seen only through a router (no MAC) is kept by address
/// until a source supplies its MAC, at which point the two records become one.
public struct NetworkDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var subnetID: Int64
    public var mac: String?
    public var currentIP: String?
    public var displayName: String?
    public var hostname: String?
    public var hostnameSource: NetworkObservationSource?
    public var vendor: String?
    public var deviceType: NetworkDeviceType
    public var notes: String?
    /// Offline and back-online alerts are sent only for watched devices:
    /// phones and laptops come and go all day.
    public var isWatched: Bool
    public var isIgnored: Bool
    /// For addresses legitimately shared (VRRP/HSRP, a cluster IP).
    public var ignoreConflicts: Bool
    public var state: NetworkDeviceState
    public var missedScans: Int
    public var vlanID: Int?
    public var switchName: String?
    public var switchPort: String?
    public var firstSeenAt: Date
    /// When a presence-proving source last saw it; `nil` if none ever has.
    public var lastSeenAt: Date?
    public var lastAlertKind: String?
    public var lastAlertSentAt: Date?

    public init(
        id: Int64? = nil, subnetID: Int64, mac: String?, currentIP: String?, displayName: String? = nil,
        hostname: String? = nil, hostnameSource: NetworkObservationSource? = nil, vendor: String? = nil,
        deviceType: NetworkDeviceType = .unknown, notes: String? = nil, isWatched: Bool = false,
        isIgnored: Bool = false, ignoreConflicts: Bool = false, state: NetworkDeviceState = .unknown,
        missedScans: Int = 0, vlanID: Int? = nil, switchName: String? = nil, switchPort: String? = nil,
        firstSeenAt: Date = Date(), lastSeenAt: Date? = nil, lastAlertKind: String? = nil, lastAlertSentAt: Date? = nil
    ) {
        self.id = id
        self.subnetID = subnetID
        self.mac = mac
        self.currentIP = currentIP
        self.displayName = displayName
        self.hostname = hostname
        self.hostnameSource = hostnameSource
        self.vendor = vendor
        self.deviceType = deviceType
        self.notes = notes
        self.isWatched = isWatched
        self.isIgnored = isIgnored
        self.ignoreConflicts = ignoreConflicts
        self.state = state
        self.missedScans = missedScans
        self.vlanID = vlanID
        self.switchName = switchName
        self.switchPort = switchPort
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastAlertKind = lastAlertKind
        self.lastAlertSentAt = lastAlertSentAt
    }

    /// What the device is called everywhere in the UI and in alerts.
    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return hostname ?? currentIP ?? mac ?? "?"
    }

    public var macAddress: MACAddress? { mac.flatMap(MACAddress.init) }
    public var ipAddress: IPv4Address? { currentIP.flatMap(IPv4Address.init) }
    public var hasPrivateMAC: Bool { macAddress?.isLocallyAdministered ?? false }
}

extension NetworkDevice: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_devices"

    enum CodingKeys: String, CodingKey {
        case id, mac, hostname, vendor, notes, state
        case subnetID = "subnet_id"
        case currentIP = "current_ip"
        case displayName = "display_name"
        case hostnameSource = "hostname_source"
        case deviceType = "device_type"
        case isWatched = "is_watched"
        case isIgnored = "is_ignored"
        case ignoreConflicts = "ignore_conflicts"
        case missedScans = "missed_scans"
        case vlanID = "vlan_id"
        case switchName = "switch_name"
        case switchPort = "switch_port"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case lastAlertKind = "last_alert_kind"
        case lastAlertSentAt = "last_alert_sent_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One address a device held, from when to when it was seen with it.
public struct NetworkIPHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var deviceID: Int64
    public var ip: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

extension NetworkIPHistoryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_ip_history"

    enum CodingKeys: String, CodingKey {
        case id, ip
        case deviceID = "device_id"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Which source saw a device at which address, first and last.
public struct NetworkSighting: Codable, Equatable, Sendable {
    public var deviceID: Int64
    public var source: NetworkObservationSource
    /// 0 for this Mac's own scans.
    public var sourceID: Int64
    public var ip: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

extension NetworkSighting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "network_sightings"

    enum CodingKeys: String, CodingKey {
        case source, ip
        case deviceID = "device_id"
        case sourceID = "source_id"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }
}

public enum NetworkEventKind: String, Codable, Sendable, CaseIterable {
    /// First seen on the network.
    case discovered
    case online
    case offline
    /// The device moved to another address.
    case ipChanged = "ip_changed"
    /// The address moved to another device.
    case ipOwnerChanged = "ip_owner_changed"
    /// Two devices keep taking the same address.
    case conflict
    case merged
    case sourceFailed = "source_failed"
    case sourceRecovered = "source_recovered"
    case portOpened = "port_opened"
    case portClosed = "port_closed"
}

/// Something that happened, kept as the device's activity and the source
/// of every Network alert.
public struct NetworkEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var deviceID: Int64?
    public var subnetID: Int64?
    public var sourceID: Int64?
    public var kind: NetworkEventKind
    public var ip: String?
    /// Kind-specific: the previous address, the other device's id, a port…
    public var detail: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil, deviceID: Int64? = nil, subnetID: Int64? = nil, sourceID: Int64? = nil,
        kind: NetworkEventKind, ip: String? = nil, detail: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.deviceID = deviceID
        self.subnetID = subnetID
        self.sourceID = sourceID
        self.kind = kind
        self.ip = ip
        self.detail = detail
        self.createdAt = createdAt
    }
}

extension NetworkEvent {
    /// `detail` of a `discovered` event from a subnet's first look: part of
    /// the starting inventory rather than a new arrival.
    public static let firstInventory = "first_inventory"
}

extension NetworkEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_events"

    enum CodingKeys: String, CodingKey {
        case id, kind, ip, detail
        case deviceID = "device_id"
        case subnetID = "subnet_id"
        case sourceID = "source_id"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct NetworkScan: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var subnetID: Int64
    /// `scheduled`, `manual`, `network_change`, `wake`.
    public var trigger: String
    public var mode: SubnetScanMode?
    public var status: NetworkScanStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var hostsProbed: Int
    public var hostsFound: Int
}

extension NetworkScan: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_scans"

    enum CodingKeys: String, CodingKey {
        case id, trigger, mode, status
        case subnetID = "subnet_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case hostsProbed = "hosts_probed"
        case hostsFound = "hosts_found"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum NetworkSourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A router or switch read over SNMP.
    case snmp
    /// A lease file read over SSH from a server in the Server Manager.
    case dhcpSSH = "dhcp_ssh"
    /// A MikroTik router's REST API.
    case dhcpMikroTik = "dhcp_mikrotik"
    /// A lease or reservation list imported from a file.
    case dhcpImport = "dhcp_import"

    public var isDHCP: Bool { self != .snmp }
    public var id: Self { self }
}

/// A device the app reads network information from. Secrets (community,
/// SNMPv3 passwords, router password) live in the Keychain under
/// `keychainRef`, never in this row.
public struct NetworkSource: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var kind: NetworkSourceKind
    public var name: String
    public var host: String
    public var port: Int
    /// SNMPv3 user, or the router's API user.
    public var username: String?
    public var snmpVersion: SNMPCredentials.Version?
    public var authProtocol: SNMPAuthProtocol?
    public var privProtocol: SNMPPrivProtocol?
    public var roles: Int
    public var leaseFormat: DHCPLeaseFormat?
    public var leasePath: String?
    public var remoteServerID: Int64?
    public var keychainRef: String
    /// The router's HTTPS certificate, pinned on first use.
    public var tlsFingerprint: String?
    public var pollIntervalSecs: Int
    public var enabled: Bool
    public var consecutiveFailures: Int
    public var lastPollAt: Date?
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var sysName: String?
    public var sysDescr: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil, kind: NetworkSourceKind, name: String, host: String = "", port: Int = 161,
        username: String? = nil, snmpVersion: SNMPCredentials.Version? = nil, authProtocol: SNMPAuthProtocol? = nil,
        privProtocol: SNMPPrivProtocol? = nil, roles: SNMPRoles = [], leaseFormat: DHCPLeaseFormat? = nil,
        leasePath: String? = nil, remoteServerID: Int64? = nil, keychainRef: String = UUID().uuidString,
        tlsFingerprint: String? = nil, pollIntervalSecs: Int = 300, enabled: Bool = true,
        consecutiveFailures: Int = 0, lastPollAt: Date? = nil, lastSuccessAt: Date? = nil, lastError: String? = nil,
        sysName: String? = nil, sysDescr: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.snmpVersion = snmpVersion
        self.authProtocol = authProtocol
        self.privProtocol = privProtocol
        self.roles = roles.rawValue
        self.leaseFormat = leaseFormat
        self.leasePath = leasePath
        self.remoteServerID = remoteServerID
        self.keychainRef = keychainRef
        self.tlsFingerprint = tlsFingerprint
        self.pollIntervalSecs = pollIntervalSecs
        self.enabled = enabled
        self.consecutiveFailures = consecutiveFailures
        self.lastPollAt = lastPollAt
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.sysName = sysName
        self.sysDescr = sysDescr
        self.createdAt = createdAt
    }

    public var snmpRoles: SNMPRoles { SNMPRoles(rawValue: roles) }
}

extension NetworkSource: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "network_sources"

    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port, username, roles, enabled
        case snmpVersion = "snmp_version"
        case authProtocol = "auth_protocol"
        case privProtocol = "priv_protocol"
        case leaseFormat = "lease_format"
        case leasePath = "lease_path"
        case remoteServerID = "remote_server_id"
        case keychainRef = "keychain_ref"
        case tlsFingerprint = "tls_fingerprint"
        case pollIntervalSecs = "poll_interval_secs"
        case consecutiveFailures = "consecutive_failures"
        case lastPollAt = "last_poll_at"
        case lastSuccessAt = "last_success_at"
        case lastError = "last_error"
        case sysName = "sys_name"
        case sysDescr = "sys_descr"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct NetworkDHCPLease: Codable, Equatable, Sendable {
    public var sourceID: Int64
    public var ip: String
    public var mac: String
    public var hostname: String?
    public var endsAt: Date?
    public var isActive: Bool
    public var isReserved: Bool
    public var syncedAt: Date
}

extension NetworkDHCPLease: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "network_dhcp_leases"

    enum CodingKeys: String, CodingKey {
        case ip, mac, hostname
        case sourceID = "source_id"
        case endsAt = "ends_at"
        case isActive = "is_active"
        case isReserved = "is_reserved"
        case syncedAt = "synced_at"
    }
}

/// The latest reading of one interface of an SNMP source, with the rates
/// worked out from the reading before it.
public struct NetworkSNMPInterface: Codable, Equatable, Sendable, Identifiable {
    public var sourceID: Int64
    public var ifIndex: Int
    public var name: String
    public var alias: String?
    public var operStatus: Int?
    public var speedMbps: Int?
    public var inOctets: Int64?
    public var outOctets: Int64?
    public var inBps: Double?
    public var outBps: Double?
    public var sampledAt: Date

    public var id: Int { ifIndex }
    public var isUp: Bool { operStatus == 1 }
}

extension NetworkSNMPInterface: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "network_snmp_interfaces"

    enum CodingKeys: String, CodingKey {
        case name, alias
        case sourceID = "source_id"
        case ifIndex = "if_index"
        case operStatus = "oper_status"
        case speedMbps = "speed_mbps"
        case inOctets = "in_octets"
        case outOctets = "out_octets"
        case inBps = "in_bps"
        case outBps = "out_bps"
        case sampledAt = "sampled_at"
    }
}

public struct NetworkSNMPSample: Codable, Equatable, Sendable {
    public var sourceID: Int64
    public var ifIndex: Int
    public var inBps: Double
    public var outBps: Double
    public var sampledAt: Date
}

extension NetworkSNMPSample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "network_snmp_samples"

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case ifIndex = "if_index"
        case inBps = "in_bps"
        case outBps = "out_bps"
        case sampledAt = "sampled_at"
    }
}

/// The latest state of one TCP port on one device.
public struct NetworkPortResult: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: Int64
    public var port: Int
    public var state: TCPPortState
    public var latencyMs: Double?
    public var scannedAt: Date

    public var id: Int { port }
}

extension NetworkPortResult: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "network_port_results"

    enum CodingKeys: String, CodingKey {
        case port, state
        case deviceID = "device_id"
        case latencyMs = "latency_ms"
        case scannedAt = "scanned_at"
    }
}
