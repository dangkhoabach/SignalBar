import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

/// Collects the SQL a block of work actually executed.
private final class StatementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) {
        lock.lock()
        statements.append(sql)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        statements.removeAll()
        lock.unlock()
    }

    /// Only the reads matter here — GRDB also emits transaction and pragma
    /// statements whose count isn't what this is measuring.
    var selectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return statements.filter { $0.uppercased().contains("SELECT") }.count
    }
}

@Suite struct TargetRepositoryOverviewTests {
    private func makeRepository(recorder: StatementRecorder) throws -> TargetRepository {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { recorder.record("\($0)") }
        }
        let app = try AppDatabase(inMemory: DatabaseQueue(configuration: configuration))
        return TargetRepository(dbQueue: app.dbQueue)
    }

    @discardableResult
    private func addTarget(_ repo: TargetRepository, _ name: String) throws -> Int64 {
        let target = try repo.add(NewTargetInput(name: name, url: "https://\(name).example.com"))
        return try #require(target.id)
    }

    /// The regression this exists for: `overview()` ran four queries per
    /// target, and `observeOverview` re-runs it after every scheduler write.
    /// What must hold is that the cost doesn't scale with the target list —
    /// asserting a fixed number instead would break on any harmless change to
    /// how the rows are fetched.
    @Test func overviewQueryCountDoesNotGrowWithTheNumberOfTargets() throws {
        let recorder = StatementRecorder()
        let repo = try makeRepository(recorder: recorder)

        try addTarget(repo, "one")
        recorder.reset()
        _ = try repo.dbQueue.read { try TargetRepository.overview($0) }
        let withOneTarget = recorder.selectCount

        for name in ["two", "three", "four", "five", "six", "seven", "eight"] {
            try addTarget(repo, name)
        }
        recorder.reset()
        _ = try repo.dbQueue.read { try TargetRepository.overview($0) }
        let withEightTargets = recorder.selectCount

        #expect(withOneTarget > 0)
        #expect(withEightTargets == withOneTarget)
    }

    /// The batched version has to return what the per-target version did.
    @Test func overviewStillReportsEachTargetsLatestCheckAndUptime() throws {
        let recorder = StatementRecorder()
        let repo = try makeRepository(recorder: recorder)
        let up = try addTarget(repo, "up")
        let down = try addTarget(repo, "down")

        try repo.storeCheckResult(
            targetId: up,
            outcome: HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 120, errorMessage: nil),
            responseTimeAlertThresholdMs: 1000
        )
        try repo.storeCheckResult(
            targetId: down,
            outcome: HttpCheckOutcome(success: false, statusCode: 500, responseTimeMs: 90, errorMessage: "boom"),
            responseTimeAlertThresholdMs: 1000
        )

        let overview = try repo.dbQueue.read { try TargetRepository.overview($0) }
        let upRow = try #require(overview.first { $0.target.id == up })
        let downRow = try #require(overview.first { $0.target.id == down })

        #expect(upRow.latestCheck?.success == true)
        #expect(upRow.latestCheck?.statusCode == 200)
        #expect(upRow.uptime24hPct == 100)
        #expect(downRow.latestCheck?.success == false)
        #expect(downRow.latestCheck?.errorMessage == "boom")
        #expect(downRow.uptime24hPct == 0)
    }

    /// A target with no checks yet has to survive the joins as an empty row
    /// rather than disappearing from the list.
    @Test func overviewKeepsTargetsThatHaveNeverBeenChecked() throws {
        let recorder = StatementRecorder()
        let repo = try makeRepository(recorder: recorder)
        try addTarget(repo, "fresh")

        let overview = try repo.dbQueue.read { try TargetRepository.overview($0) }
        #expect(overview.count == 1)
        #expect(overview[0].latestCheck == nil)
        #expect(overview[0].uptime24hPct == nil)
        #expect(overview[0].sslStatus == nil)
    }

    /// The most recent check wins when several share a timestamp, which the
    /// column's second granularity makes ordinary rather than exotic.
    @Test func overviewPicksTheLastInsertedCheckWhenTimestampsTie() throws {
        let recorder = StatementRecorder()
        let repo = try makeRepository(recorder: recorder)
        let id = try addTarget(repo, "tied")

        let timestamp = Date()
        try repo.dbQueue.write { db in
            for (index, success) in [true, false].enumerated() {
                var result = CheckResult(
                    targetId: id, checkedAt: timestamp, success: success,
                    statusCode: success ? 200 : 503, responseTimeMs: index
                )
                try result.insert(db)
            }
        }

        let overview = try repo.dbQueue.read { try TargetRepository.overview($0) }
        #expect(overview[0].latestCheck?.success == false)
    }

    @Test func overviewOnAnEmptyDatabaseReturnsNothing() throws {
        let recorder = StatementRecorder()
        let repo = try makeRepository(recorder: recorder)
        #expect(try repo.dbQueue.read { try TargetRepository.overview($0) }.isEmpty)
    }
}
