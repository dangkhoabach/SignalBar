import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct RemoteServerRepositoryTests {
    private func makeRepo() throws -> (RemoteServerRepository, InMemoryKeychainStore) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let keychain = InMemoryKeychainStore()
        return (RemoteServerRepository(dbQueue: app.dbQueue, keychain: keychain), keychain)
    }

    @Test func addStoresServerAndPasswordCredential() throws {
        let (repo, keychain) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")
        ))
        #expect(server.id != nil)
        #expect(server.authMethod == .password)
        #expect(server.port == 22)

        let credential = try repo.credential(for: server, forMutatingAction: false)
        guard case .password(let password) = credential else {
            Issue.record("Expected password credential")
            return
        }
        #expect(password == "s3cr3t")
        _ = keychain
    }

    @Test func addStoresPrivateKeyAndPassphraseSeparately() throws {
        let (repo, _) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy",
            credential: .privateKey(pem: "PEM-DATA", passphrase: "pw123")
        ))
        let credential = try repo.credential(for: server, forMutatingAction: true)
        guard case .privateKey(let pem, let passphrase) = credential else {
            Issue.record("Expected private key credential")
            return
        }
        #expect(pem == "PEM-DATA")
        #expect(passphrase == "pw123")
    }

    @Test func deleteRemovesServerAndKeychainItems() throws {
        let (repo, keychain) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")
        ))
        try repo.delete(id: server.id!)
        #expect(try repo.list().isEmpty)
        #expect(throws: KeychainStoreError.notFound) {
            _ = try keychain.readForStatusCheck(ref: server.keychainRef, kind: .password)
        }
    }

    @Test func recordHostKeyFingerprintPersists() throws {
        let (repo, _) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")
        ))
        #expect(server.hostKeyFingerprint == nil)
        try repo.recordHostKeyFingerprint(id: server.id!, fingerprint: "abc123")
        let reloaded = try repo.get(id: server.id!)
        #expect(reloaded?.hostKeyFingerprint == "abc123")
    }

    @Test func allowlistCRUD() throws {
        let (repo, _) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")
        ))
        try repo.addAllowlistEntry(serverId: server.id!, kind: .service, value: "nginx")
        var entries = try repo.allowlist(serverId: server.id!)
        #expect(entries.count == 1)
        #expect(entries[0].value == "nginx")

        try repo.removeAllowlistEntry(id: entries[0].id!)
        entries = try repo.allowlist(serverId: server.id!)
        #expect(entries.isEmpty)
    }

    @Test func commandLogRecordsAndOrdersByMostRecent() throws {
        let (repo, _) = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")
        ))
        try repo.logCommand(serverId: server.id!, action: "testConnection", exitCode: 0, outputExcerpt: "deploy")
        try repo.logCommand(serverId: server.id!, action: "serviceStatus", exitCode: 1, outputExcerpt: "inactive")

        let log = try repo.recentLog(serverId: server.id!)
        #expect(log.count == 2)
        #expect(log[0].action == "serviceStatus")
    }
}
