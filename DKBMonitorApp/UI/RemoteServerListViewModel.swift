import DKBMonitorCore
import Foundation
import Observation

/// Drives the Remote Servers list — Phase 0 of
/// docs/remote-server-management-plan.md: CRUD over `RemoteServer` plus the
/// "Test connection" action (connect, pin host key on first contact, run
/// `whoami`). Later phases add allowlisted actions on top of the same
/// `RemoteServerRepository`/`RemoteConnectionService` pair.
@MainActor
@Observable
final class RemoteServerListViewModel {
    static let shared = RemoteServerListViewModel(
        repo: AppDatabase.shared.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    )

    private let repo: RemoteServerRepository?
    private let connectionService: RemoteConnectionService?

    var servers: [RemoteServer] = []
    var errorMessage: String?
    var isPresentingAddSheet = false
    var editingServer: RemoteServer?
    var pendingDeleteId: Int64?

    /// IDs currently mid-flight in "Test connection" — same fire-and-forget
    /// pattern as `OverviewViewModel.checkingIds`.
    var testingServerIds: Set<Int64> = []
    var testResultMessages: [Int64: String] = [:]

    init(repo: RemoteServerRepository?) {
        self.repo = repo
        self.connectionService = repo.map { RemoteConnectionService(repo: $0) }
    }

    func load() {
        guard let repo else { return }
        servers = (try? repo.list()) ?? []
    }

    // MARK: - CRUD

    func addServer(_ input: NewRemoteServerInput) {
        guard let repo else { return }
        do {
            _ = try repo.add(input)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateServer(_ server: RemoteServer, newCredential: SSHAuthCredential?) {
        guard let repo else { return }
        do {
            _ = try repo.update(server, newCredential: newCredential)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: Int64) {
        guard let repo else { return }
        try? repo.delete(id: id)
        testResultMessages.removeValue(forKey: id)
        load()
    }

    // MARK: - Test connection

    func testConnection(_ server: RemoteServer) {
        guard let connectionService, let id = server.id else { return }
        testingServerIds.insert(id)
        testResultMessages.removeValue(forKey: id)
        Task {
            do {
                let whoami = try await connectionService.testConnection(server)
                testResultMessages[id] = "Connected as \(whoami)"
                load() // picks up the host key fingerprint if it was just pinned
            } catch {
                testResultMessages[id] = error.localizedDescription
            }
            testingServerIds.remove(id)
        }
    }
}
