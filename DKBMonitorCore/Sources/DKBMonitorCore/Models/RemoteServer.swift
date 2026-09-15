import Foundation
import GRDB

public enum RemoteAuthMethod: String, Codable, Sendable {
    case privateKey = "private_key"
    case password
}

/// A server the user has registered for remote management (nginx/systemd/logs
/// via SSH — docs/remote-server-management-plan.md). Never carries the actual
/// credential: `keychainRef` only points at the Keychain item holding it
/// (`KeychainStore`), and `hostKeyFingerprint` is the TOFU-pinned SSH host key
/// recorded on first successful connect (`SSHCommandRunner`), not a secret.
public struct RemoteServer: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: RemoteAuthMethod
    public var keychainRef: String
    public var groupTag: String?
    public var hostKeyFingerprint: String?
    /// Whether the scheduler polls this server for CPU/RAM/disk alerts.
    /// Off until the user asks for it — see the v4 migration for why.
    public var monitoringEnabled: Bool
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: RemoteAuthMethod,
        keychainRef: String,
        groupTag: String? = nil,
        hostKeyFingerprint: String? = nil,
        monitoringEnabled: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keychainRef = keychainRef
        self.groupTag = groupTag
        self.hostKeyFingerprint = hostKeyFingerprint
        self.monitoringEnabled = monitoringEnabled
        self.createdAt = createdAt
    }
}

extension RemoteServer: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "remote_servers"

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username
        case authMethod = "auth_method"
        case keychainRef = "keychain_ref"
        case groupTag = "group_tag"
        case hostKeyFingerprint = "host_key_fingerprint"
        case monitoringEnabled = "monitoring_enabled"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
