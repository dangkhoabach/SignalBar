import DKBMonitorCore
import Foundation
import Observation
import SwiftUI

/// Drives the `MenuBarExtra` content: CPU/RAM/temperature/battery from
/// `SystemStatsProvider`, plus a domains up/total summary from the database —
/// refreshed every 3s via a `Task.sleep` loop (same burst-avoiding shape as
/// the Scheduler, Phase 4) rather than a `Timer`.
///
/// Exposes `LocalizedStringKey` labels (not pre-formatted `String`s) so
/// Xcode's String Catalog extraction can localize them (Phase 13) — a
/// `String` handed to `Text(_:)` is shown verbatim with no catalog lookup.
@MainActor
@Observable
final class MenuBarStatsViewModel {
    private static let refreshIntervalSecs: UInt64 = 3

    // Matches `NotificationManager`'s singleton shape: one instance for the
    // app's lifetime, started once from `AppDelegate.applicationDidFinishLaunching`.
    static let shared = MenuBarStatsViewModel(
        statsProvider: SystemStatsService(),
        targetRepo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let statsProvider: SystemStatsProvider
    private let targetRepo: TargetRepository?
    private var loopTask: Task<Void, Never>?

    private var cpuPercent: Int?
    private var ramUsedGB: Double?
    private var ramTotalGB: Double?
    private var temperatureCelsius: Int?
    private var batteryPercent: Int?
    private var batteryCharging = false
    private var domainsUp: Int?
    private var domainsTotal: Int?

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

        cpuPercent = Int(stats.cpuPercent.rounded())
        ramUsedGB = Double(stats.ramUsedMB) / 1024
        ramTotalGB = Double(stats.ramTotalMB) / 1024
        temperatureCelsius = stats.cpuTempCelsius.map { Int($0.rounded()) }
        batteryPercent = stats.batteryPercent.map { Int($0.rounded()) }
        batteryCharging = stats.batteryCharging ?? false

        if let targetRepo, let summary = try? targetRepo.uptimeSummary() {
            domainsUp = summary.up
            domainsTotal = summary.total
        }
    }

    var cpuLabel: LocalizedStringKey {
        guard let cpuPercent else { return "CPU: —" }
        return "CPU: \(cpuPercent)%"
    }

    var ramLabel: LocalizedStringKey {
        guard let ramUsedGB, let ramTotalGB else { return "RAM: —" }
        return "RAM: \(ramUsedGB, specifier: "%.1f") / \(ramTotalGB, specifier: "%.1f") GB"
    }

    var temperatureLabel: LocalizedStringKey {
        guard let temperatureCelsius else { return "Temperature: N/A" }
        return "Temperature: \(temperatureCelsius)°C"
    }

    var batteryLabel: LocalizedStringKey {
        guard let batteryPercent else { return "Battery: N/A" }
        return batteryCharging ? "Battery: \(batteryPercent)% (Charging)" : "Battery: \(batteryPercent)%"
    }

    var domainsLabel: LocalizedStringKey {
        guard let domainsUp, let domainsTotal else { return "Domains: —" }
        return "Domains: \(domainsUp)/\(domainsTotal) up"
    }
}
