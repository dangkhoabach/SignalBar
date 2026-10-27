import SignalBarCore
import Foundation
import Observation

/// Drives the Remote Servers list: CRUD over `RemoteServer` plus the
/// "Test connection" action (connect, pin host key on first contact, run
/// `whoami`). Later phases add allowlisted actions on top of the same
/// `RemoteServerRepository`/`RemoteConnectionService` pair.
@MainActor
@Observable
final class RemoteServerListViewModel {
    static let shared = RemoteServerListViewModel(
        repo: AppDatabase.shared.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    )
    static let ungroupedLabel = TagGrouping.ungroupedLabel

    private let repo: RemoteServerRepository?
    private let connectionService: RemoteConnectionService?
    private var observationTask: Task<Void, Never>?

    var servers: [RemoteServer] = []
    var errorMessage: String?
    /// Non-error status text (e.g. "Imported 3 server(s)...") — kept
    /// separate from `errorMessage` so it isn't shown under an "Error" alert
    /// title.
    var infoMessage: String?
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

    /// Same shape as `OverviewViewModel.start()`, including the synchronous
    /// prefetch: `ValueObservation`'s first emission is always async, so
    /// without it the list renders empty for a beat and then jumps to N rows.
    func start() {
        guard observationTask == nil, let repo else { return }
        servers = (try? repo.list()) ?? servers

        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await snapshot in repo.observeList() {
                    guard !Task.isCancelled else { break }
                    self.servers = snapshot
                }
            } catch {
                // Keep the last known list rather than blanking the pane if
                // the stream fails — same call as OverviewViewModel makes.
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Grouping

    /// Groups by `groupTag` through the same helper the Overview list uses,
    /// minus the saved drag order — nothing here has asked for reordering or
    /// renaming groups yet, so no `preferredOrder` is passed and the sections
    /// come out alphabetical with "Ungrouped" last.
    var groupedServers: [(group: String, items: [RemoteServer])] {
        TagGrouping.groups(servers) { $0.groupTag }
    }

    // MARK: - CRUD

    func addServer(_ input: NewRemoteServerInput) {
        guard let repo else { return }
        do {
            _ = try repo.add(input)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateServer(_ server: RemoteServer, newCredential: SSHAuthCredential?) {
        guard let repo else { return }
        do {
            _ = try repo.update(server, newCredential: newCredential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: Int64) {
        guard let repo else { return }
        try? repo.delete(id: id)
        testResultMessages.removeValue(forKey: id)
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
            } catch {
                testResultMessages[id] = error.localizedDescription
            }
            testingServerIds.remove(id)
        }
    }

    // MARK: - Export / import

    /// Never includes a credential (`RemoteServerPortability`'s doc comment)
    /// — safe to share/back up without leaking a private key or password.
    func exportServers() {
        guard let repo else { return }
        if let failure = JSONDocumentPanel.export(suggestedName: "dkb-monitor-remote-servers.json", makeData: {
            try RemoteServerPortability.export(repo)
        }) {
            errorMessage = failure
        }
    }

    /// Imported servers have no credential yet — surfaced via
    /// `errorMessage` as a reminder, not a blocker; each one still shows up
    /// in the list ready to be edited.
    func importServers() {
        guard let repo else { return }
        if let failure = JSONDocumentPanel.import(apply: { data in
            let count = try RemoteServerPortability.importInto(repo, data: data)
            infoMessage = "Imported \(count) server(s). Edit each one to add its credential before connecting."
        }) {
            errorMessage = failure
        }
    }
}
