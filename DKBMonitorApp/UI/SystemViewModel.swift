import AppKit
import DKBMonitorCore
import Foundation
import Observation
import SwiftUI

/// Coarse approximation of Windows Task Manager's Status column.
/// `NSRunningApplication` exposes no "Not Responding" signal (that requires
/// pinging the app's main thread/window server, which is a much bigger
/// feature on its own), so this sticks to the 3 states AppKit already knows
/// for free: `isHidden`/`isActive`.
enum AppRunState: String {
    case active, hidden, background

    var label: LocalizedStringKey {
        switch self {
        case .active: "Active"
        case .hidden: "Hidden"
        case .background: "Background"
        }
    }
}

/// A user-facing app (not a raw OS process) and its resource usage — the
/// `ProcessListProvider` pid matched against `NSWorkspace.runningApplications`
/// for a real name/icon, Task-Manager-"Apps"-tab style.
struct AppUsage: Identifiable {
    var id: Int32
    var name: String
    var icon: NSImage?
    var cpuPercent: Double
    var memoryMB: Double
    var memoryPercent: Double
    var status: AppRunState
    /// Kept for "Quit"/"Force Quit" row actions — `terminate()`/
    /// `forceTerminate()` need the live `NSRunningApplication`, not just its
    /// pid (the app isn't sandboxed, so no extra entitlement is needed to
    /// quit another user-facing app the same way Activity Monitor does).
    var runningApplication: NSRunningApplication
}

/// Drives the System pane: polls `SystemStatsProvider` every 2s (per Mục 3)
/// and keeps a rolling 1-minute window per metric for the sparklines —
/// same `Task.sleep`-loop shape as `MenuBarStatsViewModel`/`OverviewViewModel`.
@MainActor
@Observable
final class SystemViewModel {
    private static let refreshIntervalSecs: UInt64 = 2
    /// 60 samples at 2s is a two-minute window. The previous 30 (one minute)
    /// was short enough that a spike scrolled off the sparkline before the
    /// user finished reading the number that prompted them to look.
    private static let historyLimit = 60

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
    /// Every OS process, unmatched against `NSRunningApplication`. Kept
    /// alongside `topApps` rather than replacing it: the app list is the
    /// readable default, but it hides daemons — when `mds_stores` or
    /// `kernel_task` is the one eating the CPU, the app list shows nothing
    /// unusual and the user has no way to find the real culprit.
    var allProcesses: [ProcessUsage] = []

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
        allProcesses = usages.sorted { $0.cpuPercent > $1.cpuPercent }
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
    ///
    /// Returns every matched app (no top-N cap) sorted by CPU descending —
    /// `SystemView` re-sorts/filters this on top per the Table's own sort
    /// order and search text, so the default order here only matters before
    /// the user has touched either.
    private func topApps(from usages: [ProcessUsage]) -> [AppUsage] {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter traps on
        // a repeated key, and `proc_listpids` racing a fork can hand back the
        // same slot twice. A crash every few months on a duplicate pid is a
        // steep price for a lookup table where either entry will do.
        let usageByPID = Dictionary(usages.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let totalRAMMB = Double(current.ramTotalMB)
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppUsage? in
            guard app.activationPolicy != .prohibited,
                  let usage = usageByPID[app.processIdentifier]
            else { return nil }
            let status: AppRunState = app.isHidden ? .hidden : (app.isActive ? .active : .background)
            return AppUsage(
                id: app.processIdentifier,
                name: app.localizedName ?? usage.name,
                icon: app.icon,
                cpuPercent: usage.cpuPercent,
                memoryMB: usage.memoryMB,
                memoryPercent: totalRAMMB > 0 ? usage.memoryMB / totalRAMMB * 100 : 0,
                status: status,
                runningApplication: app
            )
        }
        return apps.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func appendClamped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLimit {
            array.removeFirst(array.count - Self.historyLimit)
        }
    }
}
