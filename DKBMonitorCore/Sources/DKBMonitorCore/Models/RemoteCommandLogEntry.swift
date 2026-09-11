import Foundation
import GRDB

/// One row per executed `RemoteAction` — the audit trail called for in
/// docs/remote-server-management-plan.md's security principles. Written by
/// `RemoteCommandExecutor` after every attempt, success or failure.
public struct RemoteCommandLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var remoteServerId: Int64
    public var action: String
    public var paramsJSON: String?
    public var executedAt: Date
    public var exitCode: Int?
    public var outputExcerpt: String?

    public init(
        id: Int64? = nil,
        remoteServerId: Int64,
        action: String,
        paramsJSON: String? = nil,
        executedAt: Date = Date(),
        exitCode: Int? = nil,
        outputExcerpt: String? = nil
    ) {
        self.id = id
        self.remoteServerId = remoteServerId
        self.action = action
        self.paramsJSON = paramsJSON
        self.executedAt = executedAt
        self.exitCode = exitCode
        self.outputExcerpt = outputExcerpt
    }
}

extension RemoteCommandLogEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "remote_command_log"

    enum CodingKeys: String, CodingKey {
        case id
        case remoteServerId = "remote_server_id"
        case action
        case paramsJSON = "params_json"
        case executedAt = "executed_at"
        case exitCode = "exit_code"
        case outputExcerpt = "output_excerpt"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
