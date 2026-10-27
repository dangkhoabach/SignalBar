import SignalBarCore
import Foundation
import GRDB
import Testing
@testable import SignalBar

/// A plain dictionary standing in for the Keychain, so these tests never
/// touch the real one (and never prompt for Touch ID).
///
/// Core's test target has an identical fake, but one test target can't
/// import another's code, so this is the one duplicate the app side can't
/// avoid.
private final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    func set(ref: String, kind: KeychainSecretKind, data: Data) throws {
        storage["\(ref).\(kind.rawValue)"] = data
    }

    func delete(ref: String, kind: KeychainSecretKind) throws {
        storage.removeValue(forKey: "\(ref).\(kind.rawValue)")
    }

    func deleteAll(ref: String) throws {
        for kind: KeychainSecretKind in [.privateKey, .passphrase, .password] {
            storage.removeValue(forKey: "\(ref).\(kind.rawValue)")
        }
    }

    func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref, kind)
    }

    func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref, kind)
    }

    private func read(_ ref: String, _ kind: KeychainSecretKind) throws -> Data {
        guard let data = storage["\(ref).\(kind.rawValue)"] else { throw KeychainStoreError.notFound }
        return data
    }
}

@MainActor
@Suite struct RemoteServerListViewModelTests {
    private func makeViewModel() throws -> (RemoteServerListViewModel, RemoteServerRepository) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = RemoteServerRepository(dbQueue: app.dbQueue, keychain: FakeKeychainStore())
        return (RemoteServerListViewModel(repo: repo), repo)
    }

    private func input(_ name: String, host: String = "1.2.3.4", group: String? = nil) -> NewRemoteServerInput {
        NewRemoteServerInput(
            name: name, host: host, username: "deploy",
            credential: .password("s3cr3t"), groupTag: group
        )
    }

    // MARK: - CRUD

    @Test func addServerPersistsAndTheObservationPicksItUp() async throws {
        let (viewModel, repo) = try makeViewModel()
        viewModel.start()
        defer { viewModel.stop() }

        viewModel.addServer(input("Prod"))

        #expect(try repo.list().map(\.name) == ["Prod"])
        #expect(viewModel.errorMessage == nil)
        await expectServers(viewModel, toEqual: ["Prod"])
    }

    @Test func updateServerPersistsTheNewName() throws {
        let (viewModel, repo) = try makeViewModel()
        var server = try repo.add(input("Old"))
        server.name = "New"

        viewModel.updateServer(server, newCredential: nil)

        #expect(try repo.list().map(\.name) == ["New"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test func deleteRemovesTheServerAndItsTestResultMessage() throws {
        let (viewModel, repo) = try makeViewModel()
        let server = try repo.add(input("Prod"))
        viewModel.testResultMessages[server.id!] = "Connected as deploy"

        viewModel.delete(id: server.id!)

        #expect(try repo.list().isEmpty)
        #expect(viewModel.testResultMessages[server.id!] == nil)
    }

    /// Every action guards on the repository, so a view model built without
    /// one (the app's fallback when the database won't open) has to no-op
    /// rather than trap.
    @Test func everyActionIsANoOpWithoutARepository() {
        let viewModel = RemoteServerListViewModel(repo: nil)
        viewModel.start()
        viewModel.addServer(input("Prod"))
        viewModel.delete(id: 1)
        viewModel.stop()

        #expect(viewModel.servers.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Grouping

    @Test func groupedServersSortsGroupsAndPutsUngroupedLast() throws {
        let (viewModel, repo) = try makeViewModel()
        _ = try repo.add(input("A", host: "1.1.1.1", group: "Prod"))
        _ = try repo.add(input("B", host: "2.2.2.2", group: nil))
        _ = try repo.add(input("C", host: "3.3.3.3", group: "Dev"))
        viewModel.servers = try repo.list()

        #expect(viewModel.groupedServers.map(\.group) == ["Dev", "Prod", RemoteServerListViewModel.ungroupedLabel])
        #expect(viewModel.groupedServers.last?.items.map(\.name) == ["B"])
    }

    @Test func groupedServersIsEmptyWithNoServers() throws {
        let (viewModel, _) = try makeViewModel()
        #expect(viewModel.groupedServers.isEmpty)
    }

    // MARK: - Export / import

    /// Export is deliberately credential-free, which is what makes the file
    /// safe to share — but it also means an import can't connect until each
    /// server is given a credential, so the count has to be reported.
    @Test func exportedDataCanBeImportedIntoAnEmptyDatabase() throws {
        let (_, source) = try makeViewModel()
        _ = try source.add(input("A", host: "1.1.1.1", group: "Prod"))
        _ = try source.add(input("B", host: "2.2.2.2"))
        let data = try RemoteServerPortability.export(source)

        let (viewModel, destination) = try makeViewModel()
        let count = try RemoteServerPortability.importInto(destination, data: data)
        viewModel.servers = try destination.list()

        #expect(count == 2)
        #expect(viewModel.servers.map(\.name).sorted() == ["A", "B"])
        // Each imported server gets a fresh keychain ref with nothing behind
        // it — the credential genuinely did not travel in the file.
        for server in viewModel.servers {
            #expect(throws: (any Error).self) {
                _ = try destination.credential(for: server, forMutatingAction: false)
            }
        }
    }

    // MARK: - Helpers

    /// `ValueObservation`'s emissions are asynchronous, so a write is not
    /// reflected in `servers` on the very next line. Polls briefly rather
    /// than sleeping a fixed interval, so the test is neither flaky nor
    /// slower than it has to be.
    private func expectServers(
        _ viewModel: RemoteServerListViewModel,
        toEqual expected: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<100 {
            if viewModel.servers.map(\.name) == expected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("servers never became \(expected); last saw \(viewModel.servers.map(\.name))", sourceLocation: sourceLocation)
    }
}
