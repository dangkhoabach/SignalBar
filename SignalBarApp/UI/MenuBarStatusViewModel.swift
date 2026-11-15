import SignalBarCore
import Foundation
import Observation
import SwiftUI

/// Drives the menu bar icon and panel: the domains up/total summary and the
/// domains that are down, from the database, refreshed every 5s via a
/// `Task.sleep` loop (same burst-avoiding shape as the Scheduler) rather
/// than a `Timer`.
///
/// Exposes a `LocalizedStringKey` label (not a pre-formatted `String`) so
/// Xcode's String Catalog extraction can localize it — a `String` handed to
/// `Text(_:)` is shown verbatim with no catalog lookup.
@MainActor
@Observable
final class MenuBarStatusViewModel {
    private static let refreshIntervalSecs: UInt64 = 5

    // Matches `NotificationManager`'s singleton shape: one instance for the
    // app's lifetime, started once from `AppDelegate.applicationDidFinishLaunching`.
    static let shared = MenuBarStatusViewModel(
        targetRepo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) },
        networkRepo: AppDatabase.shared.map { NetworkRepository(dbQueue: $0.dbQueue) },
        settingsRepo: AppDatabase.shared.map { SettingsRepository(dbQueue: $0.dbQueue) }
    )

    private let targetRepo: TargetRepository?
    private let networkRepo: NetworkRepository?
    private let settingsRepo: SettingsRepository?
    private var loopTask: Task<Void, Never>?

    private var domainsUp: Int?
    private var domainsTotal: Int?
    /// Enabled domains whose latest check failed, in the main window's order.
    private(set) var downTargets: [TargetOverview] = []

    /// The Network summary line; `nil` until there is a device to count.
    private(set) var network: NetworkRepository.Summary?
    /// Whether Network problems may turn the icon red (Settings › Network).
    private(set) var networkInStatus = false
    /// Whether the panel shows the public IP (Settings › Network).
    private(set) var showsPublicIP = false

    init(targetRepo: TargetRepository?, networkRepo: NetworkRepository? = nil, settingsRepo: SettingsRepository? = nil) {
        self.targetRepo = targetRepo
        self.networkRepo = networkRepo
        self.settingsRepo = settingsRepo
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() {
        if let targetRepo, let summary = try? targetRepo.uptimeSummary() {
            domainsUp = summary.up
            domainsTotal = summary.total
        }
        if let targetRepo, let overview = try? targetRepo.overview() {
            let down = Self.down(in: overview)
            if down != downTargets { downTargets = down }
        }
        if let networkRepo, let summary = try? networkRepo.summary(since: Date().addingTimeInterval(-NetworkViewModel.recentWindow)) {
            let shown = summary.devices > 0 ? summary : nil
            if shown != network { network = shown }
        }
        let settings = try? settingsRepo?.load()
        let inStatus = settings?.networkInMenuBarStatus ?? false
        if inStatus != networkInStatus { networkInStatus = inStatus }
        let showsIP = (settings?.connectionPublicLookupEnabled ?? false) && (settings?.connectionPublicIPInMenuBar ?? false)
        if showsIP != showsPublicIP { showsPublicIP = showsIP }
    }

    /// A Network problem worth the red icon: a watched device that left, or
    /// an IP conflict today. Only when the user asked for Network in the icon.
    var hasNetworkProblem: Bool {
        guard networkInStatus, let network else { return false }
        return network.watchedOffline > 0 || network.conflictsRecently > 0
    }

    /// Drives the icon: a domain down, or a Network problem when asked for.
    var showsWarning: Bool { hasDownTargets || hasNetworkProblem }

    /// The domains to list as down: enabled, not paused, and failing at
    /// their latest check.
    nonisolated static func down(in overview: [TargetOverview], now: Date = Date()) -> [TargetOverview] {
        overview.filter { item in
            let paused = item.target.pausedIndefinitely || (item.target.pausedUntil.map { $0 > now } ?? false)
            return item.target.enabled && !paused && item.latestCheck?.success == false
        }
    }

    var hasTargets: Bool { (domainsTotal ?? 0) > 0 }

    var domainsLabel: LocalizedStringKey {
        guard let domainsUp, let domainsTotal else { return "Domains: —" }
        return "Domains: \(domainsUp)/\(domainsTotal) up"
    }

    /// Drives the menu bar icon's down-state (see `StatusBarController`) — the
    /// icon otherwise looks identical whether every domain is up or several
    /// are down, so glancing at the menu bar alone never surfaced a problem;
    /// this required opening the menu every time to find out.
    var hasDownTargets: Bool {
        guard let domainsUp, let domainsTotal else { return false }
        return domainsUp < domainsTotal
    }
}
