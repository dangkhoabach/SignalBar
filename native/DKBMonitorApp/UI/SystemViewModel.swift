import AppKit
import DKBMonitorCore
import Foundation
import Observation

/// A user-facing app (not a raw OS process) and its resource usage — the
/// `ProcessListProvider` pid matched against `NSWorkspace.runningApplications`
/// for a real name/icon, Task-Manager-"Apps"-tab style.
struct AppUsage: Identifiable {
    var id: Int32
    var name: String
    var icon: NSImage?
    var cpuPercent: Double
    var memoryMB: Double
}

/// Drives the System pane: polls `SystemStatsProvider` every 2s (per Mục 3)
/// and keeps a rolling 1-minute window per metric for the sparklines —
/// same `Task.sleep`-loop shape as `MenuBarStatsViewModel`/`OverviewViewModel`.
@MainActor
@Observable
final class SystemViewModel {
    private static let refreshIntervalSecs: UInt64 = 2
    private static let historyLimit = 30

    private static let topProcessCount = 8

    static let shared = SystemViewModel(statsProvider: SystemStatsService(), processProvider: ProcessListService())

    private let statsProvider: SystemStatsProvider
    private let processProvider: ProcessListProvider
    private var loopTask: Task<Void, Never>?

    var current = SystemStats()
    var cpuHistory: [Double] = []
    var ramHistory: [Double] = []
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var tempHistory: [Double] = []
    var topApps: [AppUsage] = []

    /// True until the first `refresh()` completes. `current` starts as all
    /// zeros (`SystemStats()`'s default init), which would otherwise flash
    /// as real "CPU: 0%" values for the brief async gap before the first
    /// real snapshot lands — this flag lets the view show a skeleton
    /// instead of misleading zeroed-out numbers.
    var hasLoadedOnce = false

    init(statsProvider: SystemStatsProvider, processProvider: ProcessListProvider) {
        self.statsProvider = statsProvider
        self.processProvider = processProvider
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

    private func refresh() async {
        let stats = await statsProvider.snapshot()
        current = stats
        appendClamped(&cpuHistory, stats.cpuPercent)
        let ramPercent = stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
        appendClamped(&ramHistory, ramPercent)
        appendClamped(&downloadHistory, stats.networkDownloadKbps)
        appendClamped(&uploadHistory, stats.networkUploadKbps)
        if let temp = stats.cpuTempCelsius {
            appendClamped(&tempHistory, temp)
        }
        let usages = await processProvider.processUsages()
        topApps = topApps(from: usages)
        hasLoadedOnce = true
    }

    /// Matches raw process usages against `NSWorkspace.runningApplications`
    /// (only user-facing apps — Dock apps and menu-bar/accessory apps, not
    /// invisible background agents/daemons) so the list reads like Task
    /// Manager's "Apps" tab instead of a wall of unfamiliar process names
    /// like `mds_stores` or `com.apple.WebKit.Networking`. Each app keeps
    /// only its own main process's usage — helper/renderer subprocesses
    /// (e.g. Chrome's per-tab processes) aren't summed in, so a heavy
    /// multi-process app can under-report versus Activity Monitor.
    private func topApps(from usages: [ProcessUsage]) -> [AppUsage] {
        let usageByPID = Dictionary(uniqueKeysWithValues: usages.map { ($0.pid, $0) })
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppUsage? in
            guard app.activationPolicy != .prohibited,
                  let usage = usageByPID[app.processIdentifier]
            else { return nil }
            return AppUsage(
                id: app.processIdentifier,
                name: app.localizedName ?? usage.name,
                icon: app.icon,
                cpuPercent: usage.cpuPercent,
                memoryMB: usage.memoryMB
            )
        }
        return Array(apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(Self.topProcessCount))
    }

    private func appendClamped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLimit {
            array.removeFirst(array.count - Self.historyLimit)
        }
    }
}
