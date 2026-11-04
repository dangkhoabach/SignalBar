import SignalBarCore
import Foundation
import Observation
import SwiftUI

/// Drives the `MenuBarExtra` icon and header: the domains up/total summary
/// from the database, refreshed every 5s via a `Task.sleep` loop (same
/// burst-avoiding shape as the Scheduler) rather than a `Timer`.
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
        targetRepo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) }
    )

    private let targetRepo: TargetRepository?
    private var loopTask: Task<Void, Never>?

    private var domainsUp: Int?
    private var domainsTotal: Int?

    init(targetRepo: TargetRepository?) {
        self.targetRepo = targetRepo
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
}
