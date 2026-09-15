import Foundation

/// Implemented by the app target using `UNUserNotificationCenter` (Phase 6).
/// `route` is an app-internal path to navigate to if the user clicks through.
public protocol NotificationSending: Sendable {
    func notify(title: String, body: String, route: String?) async
}

/// Implemented by the app target's mail module (Phase 9). Returns whether the
/// report was sent successfully — the scheduler only records the dedupe
/// period on success, matching `maybe_send_report`'s behavior.
public protocol ReportSending: Sendable {
    func sendReport(label: String, days: Int) async -> Bool
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
