import Foundation
import GRDB

/// What `kind` of thing `value` names — interpreted by
/// `RemoteCommandExecutor` (Domain layer) when deciding whether a
/// `RemoteAction`'s parameter is permitted for a given server; the DB layer
/// itself doesn't enforce anything beyond storing the pair.
public enum RemoteAllowlistKind: String, Codable, Sendable {
    case service
    case nginxConfigPath = "nginx_config_path"
    case logPath = "log_path"
}

public struct RemoteAllowlistEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var remoteServerId: Int64
    public var kind: RemoteAllowlistKind
    public var value: String

    public init(id: Int64? = nil, remoteServerId: Int64, kind: RemoteAllowlistKind, value: String) {
        self.id = id
        self.remoteServerId = remoteServerId
        self.kind = kind
        self.value = value
    }
}

extension RemoteAllowlistEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "remote_server_allowlist"

    enum CodingKeys: String, CodingKey {
        case id
        case remoteServerId = "remote_server_id"
        case kind, value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
