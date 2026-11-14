import GRDB
import Testing
@testable import SignalBarCore
@testable import SignalBar

@MainActor
@Suite struct MenuBarStatusViewModelTests {
    private func makeRepo() throws -> TargetRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return TargetRepository(dbQueue: app.dbQueue)
    }

    // `LocalizedStringKey`'s `==` compares the format-string key plus its
    // interpolated arguments, not a rendered string - so the expected side
    // has to be built with the exact same interpolation shape as the
    // production code.
    @Test func hasDownTargetsIsFalseWithNoTargets() throws {
        let model = MenuBarStatusViewModel(targetRepo: try makeRepo())
        model.refresh()

        let up = 0, total = 0
        #expect(!model.hasDownTargets)
        #expect(model.domainsLabel == "Domains: \(up)/\(total) up")
    }

    @Test func hasDownTargetsIsTrueWhenATargetIsDown() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        _ = try repo.storeCheckResult(
            targetId: target.id!,
            outcome: HttpCheckOutcome(success: false, statusCode: 500, responseTimeMs: 10, errorMessage: "boom"),
            responseTimeAlertThresholdMs: 2000
        )
        let model = MenuBarStatusViewModel(targetRepo: repo)
        model.refresh()

        #expect(model.hasDownTargets)
    }

    /// The panel lists the domain that is down, by name, and not the one
    /// that is up or the one that is paused.
    @Test func listsOnlyTheDomainsThatAreDown() throws {
        let repo = try makeRepo()
        func add(_ name: String, success: Bool) throws -> Target {
            let target = try repo.add(NewTargetInput(name: name, url: "https://\(name.lowercased()).example.com"))
            _ = try repo.storeCheckResult(
                targetId: target.id!,
                outcome: HttpCheckOutcome(success: success, statusCode: success ? 200 : 500, responseTimeMs: 10, errorMessage: success ? nil : "boom"),
                responseTimeAlertThresholdMs: 2000
            )
            return target
        }
        _ = try add("Up", success: true)
        _ = try add("Down", success: false)
        let paused = try add("Paused", success: false)
        try repo.pause(id: paused.id!, until: nil)

        let model = MenuBarStatusViewModel(targetRepo: repo)
        model.refresh()

        #expect(model.downTargets.map(\.target.name) == ["Down"])
        #expect(model.hasTargets)
    }
}
