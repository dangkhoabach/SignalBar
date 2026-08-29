import DKBMonitorCore
import Foundation
import Observation

@MainActor
@Observable
final class TargetDetailViewModel {
    private let repo: TargetRepository?
    private(set) var targetId: Int64?

    var detail: TargetDetail?
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    init(repo: TargetRepository?) {
        self.repo = repo
    }

    func load(targetId: Int64) {
        self.targetId = targetId
        detail = try? repo?.detail(targetId: targetId, historyLimit: 500)
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
