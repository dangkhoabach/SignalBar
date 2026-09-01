import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct TargetRepositoryTests {
    private func makeRepo() throws -> TargetRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return TargetRepository(dbQueue: app.dbQueue)
    }

    @Test func addInfersGroupTagFromDomain() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "Site", url: "https://tools.dangkhoabach.vn"))
        #expect(target.groupTag == "dangkhoabach.vn")
        #expect(target.id != nil)
    }

    @Test func duplicateURLIsRejectedCaseInsensitively() throws {
        let repo = try makeRepo()
        _ = try repo.add(NewTargetInput(name: "A", url: "https://Example.com"))
        #expect(throws: RepositoryError.duplicateURL) {
            _ = try repo.add(NewTargetInput(name: "B", url: "  https://example.com  "))
        }
    }

    @Test func pauseIndefinitelyThenResume() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try repo.pause(id: target.id!, until: nil)
        var reloaded = try repo.list().first!
        #expect(reloaded.isPaused())

        try repo.resume(id: target.id!)
        reloaded = try repo.list().first!
        #expect(!reloaded.isPaused())
    }

    @Test func pauseUntilFutureDateExpiresNaturally() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try repo.pause(id: target.id!, until: Date(timeIntervalSinceNow: 3600))
        let reloaded = try repo.list().first!
        #expect(reloaded.isPaused(now: Date()))
        #expect(!reloaded.isPaused(now: Date(timeIntervalSinceNow: 7200)))
    }

    @Test func reorderPersistsNewSortOrder() throws {
        let repo = try makeRepo()
        let a = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let b = try repo.add(NewTargetInput(name: "B", url: "https://b.com"))
        try repo.reorder(ids: [b.id!, a.id!])
        let ordered = try repo.list()
        #expect(ordered.map(\.name) == ["B", "A"])
    }

    @Test func renameGroupUpdatesTargetsAndOrder() throws {
        let repo = try makeRepo()
        _ = try repo.add(NewTargetInput(name: "A", url: "https://a.com", groupTag: "Old"))
        try repo.setGroupOrder(["Old", "Other"])
        try repo.renameGroup(from: "Old", to: "New")
        #expect(try repo.list().first?.groupTag == "New")
        #expect(try repo.groupOrder() == ["New", "Other"])
    }

    @Test func overviewIncludesLatestCheckAndUptime() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try repo.dbQueue.write { db in
            var result = CheckResult(targetId: target.id!, success: true, responseTimeMs: 120)
            try result.insert(db)
        }
        let overview = try repo.overview()
        #expect(overview.count == 1)
        #expect(overview[0].latestCheck?.success == true)
        #expect(overview[0].uptime24hPct == 100.0)
    }

    @Test func observeOverviewEmitsAgainWhenATargetIsAdded() async throws {
        let repo = try makeRepo()
        var iterator = repo.observeOverview().makeAsyncIterator()

        let first = try await iterator.next()
        #expect(first?.isEmpty == true)

        _ = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))

        let second = try await iterator.next()
        #expect(second?.count == 1)
        #expect(second?.first?.target.name == "A")
    }
}
