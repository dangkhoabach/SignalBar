import DKBMonitorCore
import GRDB
import Testing
@testable import DKB_Monitor

@MainActor
@Suite struct OverviewViewModelTests {
    private func makeViewModel() throws -> (OverviewViewModel, TargetRepository) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = TargetRepository(dbQueue: app.dbQueue)
        return (OverviewViewModel(repo: repo), repo)
    }

    /// Covers the code-review fix: row/toolbar "Delete" now only *arms* a
    /// pending confirmation instead of deleting immediately - the actual
    /// delete still has to go through `delete(id:)`.
    @Test func deleteRemovesTargetAndClearsSelection() throws {
        let (viewModel, repo) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        viewModel.selection = [target.id!]

        viewModel.delete(id: target.id!)

        #expect(try repo.list().isEmpty)
        #expect(!viewModel.selection.contains(target.id!))
    }

    @Test func deleteSelectedRemovesEveryTargetInSelection() throws {
        let (viewModel, repo) = try makeViewModel()
        let a = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let b = try repo.add(NewTargetInput(name: "B", url: "https://b.com"))
        _ = try repo.add(NewTargetInput(name: "C", url: "https://c.com"))
        viewModel.selection = [a.id!, b.id!]

        viewModel.deleteSelected()

        let remaining = try repo.list()
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "C")
        #expect(viewModel.selection.isEmpty)
    }

    @Test func toggleEnabledFlipsTargetState() throws {
        let (viewModel, repo) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        #expect(target.enabled)

        viewModel.toggleEnabled(TargetOverview(target: target, latestCheck: nil, sslStatus: nil, domainStatus: nil, uptime24hPct: nil))

        let reloaded = try repo.list().first!
        #expect(!reloaded.enabled)
    }
}
