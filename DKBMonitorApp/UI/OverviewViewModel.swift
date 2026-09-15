import DKBMonitorCore
import Foundation
import Observation

/// Drives the Overview list: search/filter/grouping over `TargetOverview`,
/// selection for bulk actions, and every CRUD/pause/check-now/export-import
/// action the Phase 11 UI needs.
///
/// `overviews` is kept live by GRDB's `ValueObservation` (`observeOverview()`)
/// rather than polling on a timer — it re-emits automatically whenever the
/// Scheduler (or any CRUD action here) commits a change to the observed
/// tables, so the list updates the instant the DB changes instead of up to
/// 5s late. This was deliberately deferred from Phase 2 until Phase 11 had a
/// real list to bind it to; see docs/swift-native-port-plan.md.
@MainActor
@Observable
final class OverviewViewModel {
    static let ungroupedLabel = TagGrouping.ungroupedLabel

    static let shared = OverviewViewModel(
        repo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let repo: TargetRepository?
    private var observationTask: Task<Void, Never>?

    var overviews: [TargetOverview] = []
    var searchText = ""
    var statusFilters: Set<TargetStatus> = []
    var selection: Set<Int64> = []
    var errorMessage: String?
    var editingTarget: Target?
    var isPresentingAddSheet = false

    /// Set by the row context-menu "Delete" to hold off the actual delete
    /// until the confirmationDialog (driven by this ID) is confirmed —
    /// matches the confirm-before-delete pattern SettingsView already uses
    /// for "Clear All Domains".
    var pendingDeleteId: Int64?
    /// Same idea for the toolbar's bulk "Delete" over `selection`.
    var isPresentingDeleteSelectedConfirm = false

    /// IDs currently mid-flight in a "Check Now"/"Check All Now" call.
    /// `Scheduler.checkNow` has no in-progress signal of its own (it's a
    /// fire-and-forget `async` call whose results surface later via the
    /// `observeOverview()` DB observation) — this is purely a UI-layer flag
    /// so a row/toolbar button can show a spinner while the network check
    /// it kicked off is still running.
    var checkingIds: Set<Int64> = []
    var isCheckingAll = false

    init(repo: TargetRepository?) {
        self.repo = repo
    }

    func start() {
        guard observationTask == nil, let repo else { return }

        // `ValueObservation`'s first emission always arrives asynchronously
        // (it's dispatched to GRDB's reader queue, even for the initial
        // fetch), so without this the List starts empty and jumps to N rows
        // moments after first appearing. That 0-rows-to-N-rows transition is
        // exactly what triggers AppKit's `NSTableView` (which backs `List`
        // on macOS) into caching the wrong row heights until a scroll forces
        // it to recompute — the "squished/overlapping rows on launch" bug.
        // A synchronous prefetch means the List already has real data on
        // its very first layout pass, so that transition never happens.
        overviews = (try? repo.overview()) ?? overviews

        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await snapshot in repo.observeOverview() {
                    guard !Task.isCancelled else { break }
                    self.overviews = snapshot
                }
            } catch {
                // Observation stream failed (e.g. DB connection dropped) —
                // leave the last known snapshot in place rather than crash.
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
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
        return TagGrouping.groups(filtered, preferredOrder: currentGroupOrder()) { $0.target.groupTag }
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
    }

    func deleteSelected() {
        guard let repo, !selection.isEmpty else { return }
        try? repo.delete(ids: Array(selection))
        selection.removeAll()
    }

    func setEnabledForSelection(_ enabled: Bool) {
        guard let repo, !selection.isEmpty else { return }
        try? repo.setEnabled(ids: Array(selection), enabled: enabled)
    }

    func toggleEnabled(_ overview: TargetOverview) {
        guard let repo, let id = overview.target.id else { return }
        try? repo.setEnabled(ids: [id], enabled: !overview.target.enabled)
    }

    // MARK: - Pause / resume

    func pause(id: Int64, duration: TimeInterval?) {
        guard let repo else { return }
        try? repo.pause(id: id, until: duration.map { Date().addingTimeInterval($0) })
    }

    func resume(id: Int64) {
        guard let repo else { return }
        try? repo.resume(id: id)
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
    }

    func moveToGroup(id: Int64, group: String) {
        guard let repo, var target = overviews.first(where: { $0.target.id == id })?.target else { return }
        target.groupTag = (group == Self.ungroupedLabel) ? nil : group
        try? repo.update(target)
    }

    func renameGroup(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let repo, !trimmed.isEmpty, trimmed != oldName else { return }
        try? repo.renameGroup(from: oldName, to: trimmed)
    }

    // MARK: - Check now

    func checkNow(id: Int64) {
        checkingIds.insert(id)
        Task {
            await AppScheduler.shared?.checkNow(targetIds: [id])
            checkingIds.remove(id)
        }
    }

    func checkAllNow() {
        let ids = overviews.compactMap { $0.target.id }
        guard !ids.isEmpty else { return }
        checkingIds.formUnion(ids)
        isCheckingAll = true
        Task {
            await AppScheduler.shared?.checkNow(targetIds: ids)
            checkingIds.subtract(ids)
            isCheckingAll = false
        }
    }

    // MARK: - Export / import

    func exportTargets() {
        guard let repo else { return }
        if let failure = JSONDocumentPanel.export(suggestedName: "dkb-monitor-targets.json", makeData: {
            try TargetPortability.export(targets: try repo.list())
        }) {
            errorMessage = failure
        }
    }

    func importTargets() {
        guard let repo else { return }
        if let failure = JSONDocumentPanel.import(apply: { data in
            try TargetPortability.importInto(repo, data: data)
        }) {
            errorMessage = failure
        }
    }

    /// Ports the old Tauri Settings page's destructive "Clear All Domains"
    /// action (`AlertsDataSettingsPage.handleClearAll`) — there was no
    /// equivalent bulk-wipe here yet, only per-row/selection delete from the
    /// Overview list.
    func clearAllTargets() {
        guard let repo else { return }
        do {
            let ids = try repo.list().compactMap(\.id)
            guard !ids.isEmpty else { return }
            try repo.delete(ids: ids)
        } catch {
            errorMessage = "Clear all failed: \(error.localizedDescription)"
        }
    }
}
