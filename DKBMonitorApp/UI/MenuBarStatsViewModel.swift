import DKBMonitorCore
import Foundation
import Observation
import SwiftUI

/// Drives the `MenuBarExtra` content: CPU/RAM/temperature/battery from
/// `SystemStatsProvider`, plus a domains up/total summary from the database —
/// refreshed every 5s via a `Task.sleep` loop (same burst-avoiding shape as
/// the Scheduler, Phase 4) rather than a `Timer`. Uses `snapshotLight()`
/// (not `snapshot()`) since the menu bar never shows network/GPU/disk/swap/
/// fan fields — the full snapshot would fork `route`/`networksetup`/
/// `ifconfig` processes on every tick for values nobody reads.
///
/// Exposes `LocalizedStringKey` labels (not pre-formatted `String`s) so
/// Xcode's String Catalog extraction can localize them (Phase 13) — a
/// `String` handed to `Text(_:)` is shown verbatim with no catalog lookup.
@MainActor
@Observable
final class MenuBarStatsViewModel {
    private static let refreshIntervalSecs: UInt64 = 5

    // Matches `NotificationManager`'s singleton shape: one instance for the
    // app's lifetime, started once from `AppDelegate.applicationDidFinishLaunching`.
    static let shared = MenuBarStatsViewModel(
        statsProvider: SystemStatsService(),
        targetRepo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let statsProvider: SystemStatsProvider
    private let targetRepo: TargetRepository?
    private var loopTask: Task<Void, Never>?

    /// Rolling window for the popover's sparklines. 24 samples at the 5s
    /// refresh is two minutes of history — long enough to show a spike the
    /// user just felt, short enough to stay cheap.
    private static let historyLimit = 24

    private var cpuPercent: Int?
    private var ramUsedGB: Double?
    private var ramTotalGB: Double?
    private var temperatureCelsius: Int?
    private var batteryPercent: Int?
    private var batteryCharging = false
    private var domainsUp: Int?
    private var domainsTotal: Int?

    /// The full snapshot behind the labels, for the popover's bars and
    /// per-core strip. The labels above stay as they are: they're also used
    /// by the plain-`Text` fallback menu and are localized differently.
    private(set) var stats = SystemStats()
    private(set) var cpuHistory: [Double] = []
    private(set) var ramHistory: [Double] = []

    /// `nil` until the first refresh lands, so the menu bar shows its icon
    /// alone rather than a misleading "0%" during launch.
    var cpuPercentValue: Int? { cpuPercent }

    /// Bare values for the popover, where the metric name is already its own
    /// localized `Label` — the `…Label` properties below prefix it ("CPU: 42%")
    /// and would read as a duplicate there.
    var cpuLabelValue: String {
        guard let cpuPercent else { return "—" }
        return "\(cpuPercent)%"
    }

    var ramLabelValue: String {
        guard let ramUsedGB, let ramTotalGB else { return "—" }
        return String(format: "%.1f / %.1f GB", ramUsedGB, ramTotalGB)
    }

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
        let stats = await statsProvider.snapshotLight()
        self.stats = stats

        appendClamped(&cpuHistory, stats.cpuPercent)
        appendClamped(&ramHistory, stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0)

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

    /// Drives the menu bar icon's down-state (see `MenuBarIconView`) — the
    /// icon otherwise looks identical whether every domain is up or several
    /// are down, so glancing at the menu bar alone never surfaced a problem;
    /// this required opening the menu every time to find out.
    var hasDownTargets: Bool {
        guard let domainsUp, let domainsTotal else { return false }
        return domainsUp < domainsTotal
    }

    /// Injects a fabricated snapshot for `LayoutSnapshot` only, so the
    /// popover's per-core strip can be rendered against machine shapes this
    /// Mac isn't (a 16-core M2 Ultra, an Intel box with no clusters). The
    /// polling loop is stopped by the caller for the duration; `stats` stays
    /// `private(set)` for every other caller.
    func overrideStatsForSnapshot(_ stats: SystemStats) {
        self.stats = stats
        cpuPercent = Int(stats.cpuPercent.rounded())
        ramUsedGB = Double(stats.ramUsedMB) / 1024
        ramTotalGB = Double(stats.ramTotalMB) / 1024
    }

    private func appendClamped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLimit {
            array.removeFirst(array.count - Self.historyLimit)
        }
    }
}
