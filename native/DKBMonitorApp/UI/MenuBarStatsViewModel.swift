import DKBMonitorCore
import Foundation
import Observation

/// Drives the `MenuBarExtra` content: CPU/RAM/temperature/battery from
/// `SystemStatsProvider`, plus a domains up/total summary from the database —
/// refreshed every 3s via a `Task.sleep` loop (same burst-avoiding shape as
/// the Scheduler, Phase 4) rather than a `Timer`.
@MainActor
@Observable
final class MenuBarStatsViewModel {
    private static let refreshIntervalSecs: UInt64 = 3

    // Matches `NotificationManager`'s singleton shape: one instance for the
    // app's lifetime, started once from `AppDelegate.applicationDidFinishLaunching`.
    static let shared = MenuBarStatsViewModel(
        statsProvider: SystemStatsService(),
        targetRepo: (try? AppDatabase(path: AppDatabaseLocation.productionPath().path)).map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let statsProvider: SystemStatsProvider
    private let targetRepo: TargetRepository?
    private var loopTask: Task<Void, Never>?

    var cpuText = "CPU: —"
    var ramText = "RAM: —"
    var temperatureText = "Temperature: —"
    var batteryText = "Battery: —"
    var domainsText = "Domains: —"

    init(statsProvider: SystemStatsProvider, targetRepo: TargetRepository?) {
        self.statsProvider = statsProvider
        self.targetRepo = targetRepo
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        let stats = await statsProvider.snapshot()

        cpuText = "CPU: \(Int(stats.cpuPercent.rounded()))%"
        ramText = String(format: "RAM: %.1f / %.1f GB", Double(stats.ramUsedMB) / 1024, Double(stats.ramTotalMB) / 1024)
        temperatureText = stats.cpuTempCelsius.map { "Temperature: \(Int($0.rounded()))°C" } ?? "Temperature: N/A"
        batteryText = formattedBattery(percent: stats.batteryPercent, charging: stats.batteryCharging)

        if let targetRepo, let summary = try? targetRepo.uptimeSummary() {
            domainsText = "Domains: \(summary.up)/\(summary.total) up"
        }
    }

    private func formattedBattery(percent: Double?, charging: Bool?) -> String {
        guard let percent else { return "Battery: N/A" }
        let rounded = Int(percent.rounded())
        return (charging ?? false) ? "Battery: \(rounded)% (Charging)" : "Battery: \(rounded)%"
    }
}
