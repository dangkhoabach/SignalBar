import GRDB
import Testing
@testable import SignalBarCore
@testable import SignalBar

/// Always returns the same fixed snapshot - enough to exercise
/// `MenuBarStatsViewModel`'s label formatting without touching real
/// hardware sensors.
private struct StubStatsProvider: SystemStatsProvider {
    func snapshot() async -> SystemStats {
        SystemStats(cpuPercent: 42, ramUsedMB: 2048, ramTotalMB: 4096, cpuTempCelsius: 55, batteryPercent: 80, batteryCharging: true)
    }
}

@MainActor
@Suite struct MenuBarStatsViewModelTests {
    private func makeRepo() throws -> TargetRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return TargetRepository(dbQueue: app.dbQueue)
    }

    // `LocalizedStringKey`'s `==` compares the format-string key plus its
    // interpolated arguments, not a rendered string - a plain string literal
    // like `"CPU: 42%"` has no arguments and never equals an interpolated
    // key even when they'd render identically, so the expected side has to
    // be built with the exact same interpolation shape as the production code.
    @Test func refreshFormatsStatsIntoLabels() async throws {
        let model = MenuBarStatsViewModel(statsProvider: StubStatsProvider(), targetRepo: try makeRepo())
        await model.refresh()

        let cpuPercent = 42
        let ramUsedGB = 2.0, ramTotalGB = 4.0
        let temperatureCelsius = 55
        let batteryPercent = 80

        #expect(model.cpuLabel == "CPU: \(cpuPercent)%")
        #expect(model.ramLabel == "RAM: \(ramUsedGB, specifier: "%.1f") / \(ramTotalGB, specifier: "%.1f") GB")
        #expect(model.temperatureLabel == "Temperature: \(temperatureCelsius)°C")
        #expect(model.batteryLabel == "Battery: \(batteryPercent)% (Charging)")
    }

    @Test func hasDownTargetsIsFalseWithNoTargets() async throws {
        let model = MenuBarStatsViewModel(statsProvider: StubStatsProvider(), targetRepo: try makeRepo())
        await model.refresh()

        let up = 0, total = 0
        #expect(!model.hasDownTargets)
        #expect(model.domainsLabel == "Domains: \(up)/\(total) up")
    }

    @Test func hasDownTargetsIsTrueWhenATargetIsDown() async throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        _ = try repo.storeCheckResult(
            targetId: target.id!,
            outcome: HttpCheckOutcome(success: false, statusCode: 500, responseTimeMs: 10, errorMessage: "boom"),
            responseTimeAlertThresholdMs: 2000
        )
        let model = MenuBarStatsViewModel(statsProvider: StubStatsProvider(), targetRepo: repo)
        await model.refresh()

        #expect(model.hasDownTargets)
    }
}
