import AppKit
import DKBMonitorCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Drives the Overview list: search/filter/grouping over `TargetOverview`,
/// selection for bulk actions, and every CRUD/pause/check-now/export-import
/// action the Phase 11 UI needs. Refreshed every 5s via the same
/// `Task.sleep`-loop shape as `MenuBarStatsViewModel` (Phase 7).
@MainActor
@Observable
final class OverviewViewModel {
    private static let refreshIntervalSecs: UInt64 = 5
    static let ungroupedLabel = "Ungrouped"

    static let shared = OverviewViewModel(
        repo: (try? AppDatabase(path: AppDatabaseLocation.productionPath().path)).map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let repo: TargetRepository?
    private var loopTask: Task<Void, Never>?

    var overviews: [TargetOverview] = []
    var searchText = ""
    var statusFilters: Set<TargetStatus> = []
    var selection: Set<Int64> = []
    var errorMessage: String?
    var editingTarget: Target?
    var isPresentingAddSheet = false

    init(repo: TargetRepository?) {
        self.repo = repo
    }

    func start() {
        guard loopTask == nil else { return }
        refresh()
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
                self.refresh()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() {
        guard let repo else { return }
        overviews = (try? repo.overview()) ?? []
    }

    // MARK: - Search / filter / grouping

    var filteredGroups: [(group: String, items: [TargetOverview])] {
        let filtered = overviews.filter { overview in
            let matchesSearch = searchText.isEmpty
                || overview.target.name.localizedCaseInsensitiveContains(searchText)
                || overview.target.url.localizedCaseInsensitiveContains(searchText)
            let matchesStatus = statusFilters.isEmpty || statusFilters.contains(TargetStatus(overview: overview))
            return matchesSearch && matchesStatus
        }
        let grouped = Dictionary(grouping: filtered) { $0.target.groupTag ?? Self.ungroupedLabel }
        var orderedNames = currentGroupOrder().filter { grouped[$0] != nil }
        let remaining = grouped.keys.filter { !orderedNames.contains($0) && $0 != Self.ungroupedLabel }.sorted()
        orderedNames.append(contentsOf: remaining)
        if grouped[Self.ungroupedLabel] != nil { orderedNames.append(Self.ungroupedLabel) }
        return orderedNames.map { (group: $0, items: grouped[$0] ?? []) }
    }

    private func currentGroupOrder() -> [String] {
        guard let repo else { return [] }
        return (try? repo.groupOrder()) ?? []
    }

    // MARK: - CRUD

    func addTarget(_ input: NewTargetInput) {
        guard let repo else { return }
        do {
            _ = try repo.add(input)
            refresh()
        } catch RepositoryError.duplicateURL {
            errorMessage = "A target with this URL already exists."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateTarget(_ target: Target) {
        guard let repo else { return }
        do {
            _ = try repo.update(target)
            refresh()
        } catch RepositoryError.duplicateURL {
            errorMessage = "A target with this URL already exists."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: Int64) {
        guard let repo else { return }
        try? repo.delete(id: id)
        selection.remove(id)
        refresh()
    }

    func deleteSelected() {
        guard let repo, !selection.isEmpty else { return }
        try? repo.delete(ids: Array(selection))
        selection.removeAll()
        refresh()
    }

    func setEnabledForSelection(_ enabled: Bool) {
        guard let repo, !selection.isEmpty else { return }
        try? repo.setEnabled(ids: Array(selection), enabled: enabled)
        refresh()
    }

    func toggleEnabled(_ overview: TargetOverview) {
        guard let repo, let id = overview.target.id else { return }
        try? repo.setEnabled(ids: [id], enabled: !overview.target.enabled)
        refresh()
    }

    // MARK: - Pause / resume

    func pause(id: Int64, duration: TimeInterval?) {
        guard let repo else { return }
        try? repo.pause(id: id, until: duration.map { Date().addingTimeInterval($0) })
        refresh()
    }

    func resume(id: Int64) {
        guard let repo else { return }
        try? repo.resume(id: id)
        refresh()
    }

    // MARK: - Ordering / grouping

    /// Reorders `items` (one group's rows) in place while preserving every
    /// other group's relative position in the shared `sort_order` sequence.
    func moveWithinGroup(_ items: [TargetOverview], from source: IndexSet, to destination: Int) {
        guard let repo else { return }
        var reordered = items.map { $0.target.id ?? -1 }
        reordered.move(fromOffsets: source, toOffset: destination)

        var allIds = overviews.map { $0.target.id ?? -1 }
        let groupIds = Set(reordered)
        var cursor = 0
        for index in allIds.indices where groupIds.contains(allIds[index]) {
            allIds[index] = reordered[cursor]
            cursor += 1
        }
        try? repo.reorder(ids: allIds)
        refresh()
    }

    func moveToGroup(id: Int64, group: String) {
        guard let repo, var target = overviews.first(where: { $0.target.id == id })?.target else { return }
        target.groupTag = (group == Self.ungroupedLabel) ? nil : group
        try? repo.update(target)
        refresh()
    }

    func renameGroup(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let repo, !trimmed.isEmpty, trimmed != oldName else { return }
        try? repo.renameGroup(from: oldName, to: trimmed)
        refresh()
    }

    // MARK: - Check now

    func checkNow(id: Int64) {
        Task {
            await AppScheduler.shared?.checkNow(targetIds: [id])
            refresh()
        }
    }

    func checkAllNow() {
        let ids = overviews.compactMap { $0.target.id }
        guard !ids.isEmpty else { return }
        Task {
            await AppScheduler.shared?.checkNow(targetIds: ids)
            refresh()
        }
    }

    // MARK: - Export / import

    func exportTargets() {
        guard let repo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dkb-monitor-targets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try TargetPortability.export(targets: try repo.list())
            try data.write(to: url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importTargets() {
        guard let repo else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try TargetPortability.importInto(repo, data: data)
            refresh()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
