import AppKit
import DKBMonitorCore
import Foundation
import Observation
import UniformTypeIdentifiers

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
    static let ungroupedLabel = "Ungrouped"

    private let repo: RemoteServerRepository?
    private let connectionService: RemoteConnectionService?

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

    func load() {
        guard let repo else { return }
        servers = (try? repo.list()) ?? []
    }

    // MARK: - Grouping

    /// Groups by `groupTag` the same way `OverviewViewModel.filteredGroups`
    /// groups targets — sorted group names first, "Ungrouped" always last —
    /// but without that view model's drag-reorder/rename-group machinery,
    /// which nothing here has asked for yet.
    var groupedServers: [(group: String, items: [RemoteServer])] {
        let grouped = Dictionary(grouping: servers) { $0.groupTag ?? Self.ungroupedLabel }
        var groupNames = grouped.keys.filter { $0 != Self.ungroupedLabel }.sorted()
        if grouped[Self.ungroupedLabel] != nil { groupNames.append(Self.ungroupedLabel) }
        return groupNames.map { (group: $0, items: grouped[$0] ?? []) }
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

    // MARK: - Export / import

    /// Never includes a credential (`RemoteServerPortability`'s doc comment)
    /// — safe to share/back up without leaking a private key or password.
    func exportServers() {
        guard let repo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dkb-monitor-remote-servers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try RemoteServerPortability.export(repo)
            try data.write(to: url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Imported servers have no credential yet — surfaced via
    /// `errorMessage` as a reminder, not a blocker; each one still shows up
    /// in the list ready to be edited.
    func importServers() {
        guard let repo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let count = try RemoteServerPortability.importInto(repo, data: data)
            load()
            infoMessage = "Imported \(count) server(s). Edit each one to add its credential before connecting."
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
