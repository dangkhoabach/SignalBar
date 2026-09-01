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
