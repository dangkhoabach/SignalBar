import DKBMonitorCore
import Foundation
import Observation

@MainActor
@Observable
final class TargetDetailViewModel {
    private let repo: TargetRepository?
    private(set) var targetId: Int64?
    private var observationTask: Task<Void, Never>?

    var detail: TargetDetail?
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    init(repo: TargetRepository?) {
        self.repo = repo
    }

    /// Kept live via GRDB's `ValueObservation` (same pattern as
    /// `OverviewViewModel.start()`) instead of a one-shot load, so the
    /// chart/history/uptime stay current for as long as the screen is open
    /// rather than freezing at whatever they were on `.onAppear`.
    func start(targetId: Int64) {
        guard let repo else { return }
        if self.targetId == targetId, observationTask != nil { return }
        stop()
        self.targetId = targetId

        // Synchronous prefetch so the first frame already has data, same
        // reasoning as OverviewViewModel.start().
        detail = try? repo.detail(targetId: targetId, historyLimit: 500)

        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await snapshot in repo.observeDetail(targetId: targetId, historyLimit: 500) {
                    guard !Task.isCancelled else { break }
                    self.detail = snapshot
                }
            } catch {
                // Observation stream failed - leave the last known snapshot in place.
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// `detail.history` is `checked_at` DESC (repository convention) — kept
    /// that way for the table, but charts want chronological order.
    var chronologicalHistory: [CheckResult] {
        detail?.history.reversed() ?? []
    }

    var historyForSelectedDay: [CheckResult] {
        guard let detail else { return [] }
        let calendar = Calendar.current
        return detail.history.filter { calendar.isDate($0.checkedAt, inSameDayAs: selectedDay) }
    }
}
