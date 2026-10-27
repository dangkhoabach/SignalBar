import Foundation
import GRDB
import Testing
@testable import SignalBarCore

@Suite struct RemoteServerPortabilityTests {
    private func makeRepo() throws -> RemoteServerRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore())
    }

    @Test func exportNeverIncludesTheCredential() throws {
        let repo = try makeRepo()
        _ = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t"), groupTag: "web"
        ))
        let data = try RemoteServerPortability.export(repo)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("s3cr3t"))
        #expect(json.contains("\"host\" : \"1.2.3.4\""))
    }

    @Test func exportIncludesAllowlistEntries() throws {
        let repo = try makeRepo()
        let server = try repo.add(NewRemoteServerInput(name: "Prod", host: "1.2.3.4", username: "deploy", credential: .password("s3cr3t")))
        try repo.addAllowlistEntry(serverId: server.id!, kind: .service, value: "nginx")

        let data = try RemoteServerPortability.export(repo)
        let decoded = try JSONDecoder().decode([ExportedRemoteServer].self, from: data)
        #expect(decoded.count == 1)
        // `repo.add` also seeds default nginx config/log paths (see its doc
        // comment) — this test only cares that the manually-added entry
        // round-trips through export, not that it's the *only* one.
        #expect(decoded[0].allowlist.contains(.init(kind: .service, value: "nginx")))
    }

    @Test func importCreatesServersWithoutACredential() throws {
        let sourceRepo = try makeRepo()
        let server = try sourceRepo.add(NewRemoteServerInput(
            name: "Prod", host: "1.2.3.4", username: "deploy", credential: .privateKey(pem: "PEM", passphrase: nil), groupTag: "web"
        ))
        try sourceRepo.addAllowlistEntry(serverId: server.id!, kind: .nginxConfigPath, value: "/etc/nginx/sites-available/default")
        let data = try RemoteServerPortability.export(sourceRepo)

        let destRepo = try makeRepo()
        let count = try RemoteServerPortability.importInto(destRepo, data: data)
        #expect(count == 1)

        let imported = try destRepo.list()
        #expect(imported.count == 1)
        #expect(imported[0].name == "Prod")
        #expect(imported[0].groupTag == "web")
        #expect(imported[0].authMethod == .privateKey)

        // Only the manually-added entry, plus the source's own seeded
        // defaults (see `RemoteServerRepository.add`'s doc comment) —
        // `addWithoutCredential` (used by import) doesn't seed its own, it
        // only replays whatever the export carried.
        let allowlist = try destRepo.allowlist(serverId: imported[0].id!)
        #expect(allowlist.contains { $0.value == "/etc/nginx/sites-available/default" })
        #expect(allowlist.count == 4)

        #expect(throws: KeychainStoreError.notFound) {
            _ = try destRepo.credential(for: imported[0], forMutatingAction: false)
        }
    }
}
