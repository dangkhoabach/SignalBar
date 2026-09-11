import Foundation

/// Export/import format for remote servers (Phase 5 of
/// docs/remote-server-management-plan.md) — mirrors `TargetPortability`'s
/// shape, with one deliberate difference: **never contains a credential**.
/// The private key/password lives only in Keychain and is never serialized,
/// so an imported server always starts unusable until the user edits it and
/// enters a real credential.
public struct ExportedRemoteServer: Codable, Sendable {
    public struct ExportedAllowlistEntry: Codable, Sendable, Equatable {
        public var kind: RemoteAllowlistKind
        public var value: String
    }

    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: RemoteAuthMethod
    public var groupTag: String?
    public var allowlist: [ExportedAllowlistEntry]

    public init(server: RemoteServer, allowlist: [RemoteAllowlistEntry]) {
        name = server.name
        host = server.host
        port = server.port
        username = server.username
        authMethod = server.authMethod
        groupTag = server.groupTag
        self.allowlist = allowlist.map { ExportedAllowlistEntry(kind: $0.kind, value: $0.value) }
    }
}

public enum RemoteServerPortability {
    public static func export(_ repo: RemoteServerRepository) throws -> Data {
        let servers = try repo.list()
        var exported: [ExportedRemoteServer] = []
        for server in servers {
            let allowlist = try server.id.map { try repo.allowlist(serverId: $0) } ?? []
            exported.append(ExportedRemoteServer(server: server, allowlist: allowlist))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exported)
    }

    /// Returns the number of servers actually inserted. Every one comes in
    /// with no credential (see the type's doc comment) — the UI should tell
    /// the user each imported server needs a credential before it can
    /// connect.
    @discardableResult
    public static func importInto(_ repo: RemoteServerRepository, data: Data) throws -> Int {
        let items = try JSONDecoder().decode([ExportedRemoteServer].self, from: data)
        var count = 0
        for item in items {
            let server = try repo.addWithoutCredential(
                name: item.name, host: item.host, port: item.port, username: item.username,
                authMethod: item.authMethod, groupTag: item.groupTag
            )
            if let id = server.id {
                for entry in item.allowlist {
                    try? repo.addAllowlistEntry(serverId: id, kind: entry.kind, value: entry.value)
                }
            }
            count += 1
        }
        return count
    }
}
