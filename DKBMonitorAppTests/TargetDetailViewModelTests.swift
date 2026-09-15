import DKBMonitorCore
import Foundation
import GRDB
import Testing
@testable import DKB_Monitor

@MainActor
@Suite struct TargetDetailViewModelTests {
    private func makeViewModel() throws -> (TargetDetailViewModel, TargetRepository, AppDatabase) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = TargetRepository(dbQueue: app.dbQueue)
        return (TargetDetailViewModel(repo: repo), repo, app)
    }

    private func insertChecks(_ app: AppDatabase, targetId: Int64, at dates: [Date]) throws {
        try app.dbQueue.write { db in
            for date in dates {
                var result = CheckResult(targetId: targetId, checkedAt: date, success: true, statusCode: 200, responseTimeMs: 100)
                try result.insert(db)
            }
        }
    }

    /// The table reads newest-first and the chart reads left-to-right in
    /// time, so these two orders have to stay opposites. A chart drawn from
    /// the raw history would run backwards without looking obviously wrong.
    @Test func chronologicalHistoryIsTheReverseOfTheTableOrder() throws {
        let (viewModel, repo, app) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let now = Date()
        let times = [now.addingTimeInterval(-7_200), now.addingTimeInterval(-3_600), now]
        try insertChecks(app, targetId: target.id!, at: times)

        viewModel.start(targetId: target.id!)
        defer { viewModel.stop() }

        let chronological = viewModel.chronologicalHistory.map(\.checkedAt)
        #expect(chronological == chronological.sorted())
        #expect(viewModel.detail?.history.map(\.checkedAt) == chronological.reversed())
    }

    @Test func chronologicalHistoryIsEmptyBeforeAnythingIsLoaded() throws {
        let (viewModel, _, _) = try makeViewModel()
        #expect(viewModel.chronologicalHistory.isEmpty)
        #expect(viewModel.historyForSelectedDay.isEmpty)
    }

    /// The day picker filters by calendar day, not by a 24-hour window from
    /// now — a check from 23:30 last night belongs to yesterday.
    @Test func historyForSelectedDayKeepsOnlyThatCalendarDay() throws {
        let (viewModel, repo, app) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        try insertChecks(app, targetId: target.id!, at: [
            today.addingTimeInterval(60),
            today.addingTimeInterval(3_600),
            yesterday.addingTimeInterval(84_600), // 23:30 yesterday
        ])

        viewModel.start(targetId: target.id!)
        defer { viewModel.stop() }

        viewModel.selectedDay = today
        #expect(viewModel.historyForSelectedDay.count == 2)

        viewModel.selectedDay = yesterday
        #expect(viewModel.historyForSelectedDay.count == 1)
    }

    /// The summary beside the chart has to describe the same checks the
    /// chart draws, or the two disagree on screen.
    @Test func latencyPercentilesCoverExactlyTheChartedChecks() throws {
        let (viewModel, repo, app) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let now = Date()
        try app.dbQueue.write { db in
            for (index, ms) in [100, 200, 300, 400].enumerated() {
                var result = CheckResult(
                    targetId: target.id!, checkedAt: now.addingTimeInterval(Double(index) * -60),
                    success: true, statusCode: 200, responseTimeMs: ms
                )
                try result.insert(db)
            }
        }

        viewModel.start(targetId: target.id!)
        defer { viewModel.stop() }

        let percentiles = try #require(viewModel.latencyPercentiles)
        #expect(percentiles.sampleCount == viewModel.chronologicalHistory.count)
        #expect(percentiles.p50 == 200)
        #expect(percentiles.p95 == 400)
    }

    @Test func thereAreNoPercentilesUntilSomethingHasSucceeded() throws {
        let (viewModel, repo, app) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try app.dbQueue.write { db in
            var result = CheckResult(targetId: target.id!, success: false, responseTimeMs: 30_000)
            try result.insert(db)
        }

        viewModel.start(targetId: target.id!)
        defer { viewModel.stop() }

        #expect(viewModel.latencyPercentiles == nil)
    }

    @Test func startPrefetchesSynchronouslySoTheFirstFrameHasData() throws {
        let (viewModel, repo, _) = try makeViewModel()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))

        viewModel.start(targetId: target.id!)
        defer { viewModel.stop() }

        #expect(viewModel.detail?.target.id == target.id)
        #expect(viewModel.targetId == target.id)
    }

    /// Navigating from one target to another has to drop the previous
    /// target's observation; otherwise both keep writing to `detail` and the
    /// screen flickers between two targets on every scheduler write.
    @Test func startingAnotherTargetReplacesTheFirstOne() throws {
        let (viewModel, repo, _) = try makeViewModel()
        let first = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let second = try repo.add(NewTargetInput(name: "B", url: "https://b.com"))

        viewModel.start(targetId: first.id!)
        viewModel.start(targetId: second.id!)
        defer { viewModel.stop() }

        #expect(viewModel.targetId == second.id)
        #expect(viewModel.detail?.target.id == second.id)
    }

    @Test func startingATargetThatDoesNotExistLeavesNoDetail() throws {
        let (viewModel, _, _) = try makeViewModel()
        viewModel.start(targetId: 999)
        defer { viewModel.stop() }
        #expect(viewModel.detail == nil)
    }
}
