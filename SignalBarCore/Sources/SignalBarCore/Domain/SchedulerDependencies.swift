import Foundation

/// Implemented by the app target using `UNUserNotificationCenter`.
/// `route` is an app-internal path to navigate to if the user clicks through.
public protocol NotificationSending: Sendable {
    func notify(title: String, body: String, route: String?) async
}

/// Implemented by the app target's mail module. Returns whether the
/// report was sent successfully — the scheduler only records the dedupe
/// period on success, matching `maybe_send_report`'s behavior.
public protocol ReportSending: Sendable {
    func sendReport(label: String, days: Int) async -> Bool
}

/// Runs a scheduled cleanup. Implemented by the app target, since moving
/// items to the Trash needs AppKit — the same split as `JunkCleanerService`.
public protocol CleanupRunning: Sendable {
    /// Every target this build knows how to clean, so the scheduler can
    /// intersect the user's saved paths against what actually exists rather
    /// than trusting stored strings.
    func availableTargets() async -> [JunkTarget]
    /// Returns bytes moved to the Trash, and the names of anything that could
    /// not be fully cleared.
    func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String])
}

/// Supplies one monitored server's CPU/RAM/disk reading.
///
/// Injected rather than built inside the scheduler so the alert logic can be
/// tested without an SSH daemon or the real Keychain — the same reason
/// `SystemStatsProvider` exists for the local machine.
public protocol RemoteStatsProviding: Sendable {
    /// The servers the user has opted into monitoring.
    func monitoredServers() throws -> [RemoteServer]
    func stats(for server: RemoteServer) async throws -> RemoteServerStats
}
