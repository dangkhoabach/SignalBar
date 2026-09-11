import Foundation
import GRDB

public struct NewRemoteServerInput: Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHAuthCredential
    public var groupTag: String?

    public init(
        name: String, host: String, port: Int = 22, username: String,
        credential: SSHAuthCredential, groupTag: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.groupTag = groupTag
    }
}

/// CRUD for `RemoteServer`/allowlist/command-log rows, plus the Keychain
/// read/write that always accompanies a server's credential — mirrors
/// `TargetRepository`'s shape. Doesn't itself open any SSH connection; that's
/// `RemoteConnectionService`/`RemoteCommandExecutor` (Domain layer), which
/// depend on this repository rather than the other way around.
public struct RemoteServerRepository: Sendable {
    let dbQueue: DatabaseQueue
    let keychain: KeychainStoring

    public init(dbQueue: DatabaseQueue, keychain: KeychainStoring = KeychainStore()) {
        self.dbQueue = dbQueue
        self.keychain = keychain
    }

    // MARK: - CRUD

    public func list() throws -> [RemoteServer] {
        try dbQueue.read { db in try RemoteServer.order(sql: "created_at ASC").fetchAll(db) }
    }

    public func get(id: Int64) throws -> RemoteServer? {
        try dbQueue.read { db in try RemoteServer.fetchOne(db, key: id) }
    }

    public func add(_ input: NewRemoteServerInput) throws -> RemoteServer {
        let ref = UUID().uuidString
        try storeCredential(ref: ref, credential: input.credential)

        var server = RemoteServer(
            name: input.name, host: input.host, port: input.port, username: input.username,
            authMethod: input.credential.authMethod, keychainRef: ref, groupTag: input.groupTag
        )
        try dbQueue.write { db in try server.insert(db) }
        return server
    }

    /// Inserts a server row with **no Keychain credential** — used only by
    /// `RemoteServerPortability.importInto`, since an export file never
    /// contains a secret (docs/remote-server-management-plan.md's security
    /// principles). The row is unusable (any connect attempt fails with
    /// `KeychainStoreError.notFound`) until the user edits it and enters a
    /// real credential.
    public func addWithoutCredential(
        name: String, host: String, port: Int = 22, username: String,
        authMethod: RemoteAuthMethod, groupTag: String? = nil
    ) throws -> RemoteServer {
        var server = RemoteServer(
            name: name, host: host, port: port, username: username,
            authMethod: authMethod, keychainRef: UUID().uuidString, groupTag: groupTag
        )
        try dbQueue.write { db in try server.insert(db) }
        return server
    }

    /// Updates the server row; pass `newCredential` only when the user
    /// actually changed auth in the edit form — otherwise the existing
    /// Keychain item (still referenced by the same `keychainRef`) is left
    /// untouched.
    public func update(_ server: RemoteServer, newCredential: SSHAuthCredential? = nil) throws -> RemoteServer {
        var server = server
        if let newCredential {
            try storeCredential(ref: server.keychainRef, credential: newCredential)
            server.authMethod = newCredential.authMethod
        }
        try dbQueue.write { db in try server.update(db) }
        return server
    }

    public func delete(id: Int64) throws {
        let server = try dbQueue.read { db in try RemoteServer.fetchOne(db, key: id) }
        _ = try dbQueue.write { db in try RemoteServer.deleteOne(db, key: id) }
        if let server {
            try? keychain.deleteAll(ref: server.keychainRef)
        }
    }

    /// Called once, the first time a server is ever reached successfully —
    /// pins the TOFU host key so every later connection is checked against
    /// it (see `SSHCommandRunner`'s `TOFUHostKeyValidator`).
    public func recordHostKeyFingerprint(id: Int64, fingerprint: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE remote_servers SET host_key_fingerprint = ? WHERE id = ?",
                arguments: [fingerprint, id]
            )
        }
    }

    // MARK: - Credential

    /// Reads the credential back out of the Keychain for connecting —
    /// `forMutatingAction` picks which authentication window
    /// (`KeychainStore.readForMutatingAction`/`readForStatusCheck`) governs
    /// how eagerly this re-prompts Touch ID/passcode.
    public func credential(for server: RemoteServer, forMutatingAction: Bool) throws -> SSHAuthCredential {
        let read = forMutatingAction ? keychain.readForMutatingAction : keychain.readForStatusCheck
        switch server.authMethod {
        case .password:
            let data = try read(server.keychainRef, .password)
            guard let password = String(data: data, encoding: .utf8) else { throw KeychainStoreError.notFound }
            return .password(password)
        case .privateKey:
            let pemData = try read(server.keychainRef, .privateKey)
            guard let pem = String(data: pemData, encoding: .utf8) else { throw KeychainStoreError.notFound }
            let passphrase: String?
            if let passData = try? read(server.keychainRef, .passphrase),
               let text = String(data: passData, encoding: .utf8), !text.isEmpty {
                passphrase = text
            } else {
                passphrase = nil
            }
            return .privateKey(pem: pem, passphrase: passphrase)
        }
    }

    private func storeCredential(ref: String, credential: SSHAuthCredential) throws {
        switch credential {
        case .password(let password):
            try keychain.set(ref: ref, kind: .password, data: Data(password.utf8))
        case .privateKey(let pem, let passphrase):
            try keychain.set(ref: ref, kind: .privateKey, data: Data(pem.utf8))
            if let passphrase, !passphrase.isEmpty {
                try keychain.set(ref: ref, kind: .passphrase, data: Data(passphrase.utf8))
            }
        }
    }

    // MARK: - Allowlist

    public func allowlist(serverId: Int64) throws -> [RemoteAllowlistEntry] {
        try dbQueue.read { db in
            try RemoteAllowlistEntry
                .filter(sql: "remote_server_id = ?", arguments: [serverId])
                .fetchAll(db)
        }
    }

    public func addAllowlistEntry(serverId: Int64, kind: RemoteAllowlistKind, value: String) throws {
        try dbQueue.write { db in
            var entry = RemoteAllowlistEntry(remoteServerId: serverId, kind: kind, value: value)
            try entry.insert(db)
        }
    }

    public func removeAllowlistEntry(id: Int64) throws {
        _ = try dbQueue.write { db in try RemoteAllowlistEntry.deleteOne(db, key: id) }
    }

    // MARK: - Command log (audit trail)

    public func logCommand(
        serverId: Int64, action: String, paramsJSON: String? = nil,
        exitCode: Int?, outputExcerpt: String?
    ) throws {
        try dbQueue.write { db in
            var entry = RemoteCommandLogEntry(
                remoteServerId: serverId, action: action, paramsJSON: paramsJSON,
                exitCode: exitCode, outputExcerpt: outputExcerpt
            )
            try entry.insert(db)
        }
    }

    // `executed_at` only has second-level resolution (SQLite `datetime('now')`),
    // so two log entries written within the same second need `id DESC` as a
    // tiebreaker to keep "most recent first" actually true.
    public func recentLog(serverId: Int64, limit: Int = 50) throws -> [RemoteCommandLogEntry] {
        try dbQueue.read { db in
            try RemoteCommandLogEntry
                .filter(sql: "remote_server_id = ?", arguments: [serverId])
                .order(sql: "executed_at DESC, id DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }
}

extension SSHAuthCredential {
    fileprivate var authMethod: RemoteAuthMethod {
        switch self {
        case .privateKey: .privateKey
        case .password: .password
        }
    }
}
