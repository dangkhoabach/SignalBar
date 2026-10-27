import Foundation
import GRDB

/// Delivers an alert somewhere other than this Mac's notification centre.
///
/// Separate from `NotificationSending` because the two answer different
/// questions: a macOS notification tells whoever is sitting at this machine,
/// a webhook tells a team channel that is being watched when nobody is.
/// They are toggled independently for the same reason.
public protocol AlertWebhookSending: Sendable {
    func send(title: String, body: String, route: String?) async
}

/// Posts alerts to a user-configured Slack, Discord, or plain webhook URL.
///
/// Unlike the email report, this involves no relay of ours: the request goes
/// straight from this Mac to the URL the user entered, so nothing about the
/// monitored domains passes through a third party that the user didn't
/// choose themselves.
public struct WebhookAlertSender: AlertWebhookSending {
    private let dbQueue: DatabaseQueue

    /// Short by design. This runs inside the scheduler tick, and a webhook
    /// endpoint that hangs must not hold up the checks behind it — a missed
    /// alert is better than a stalled monitor.
    static let timeoutSeconds: TimeInterval = 10

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func send(title: String, body: String, route: String?) async {
        guard let settings = try? SettingsRepository(dbQueue: dbQueue).load(),
              settings.webhookEnabled,
              let url = URL(string: settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https"
        else { return }

        await Self.post(to: url, title: title, body: body, route: route)
    }

    /// Returns whether the endpoint accepted it — used by the "Send test"
    /// button, and ignored by the scheduler, which has nowhere to report a
    /// failed alert to anyway.
    @discardableResult
    public static func post(to url: URL, title: String, body: String, route: String?) async -> Bool {
        let payload = AlertWebhook.payload(
            for: WebhookDestination.forURL(url), title: title, body: body, route: route
        )
        guard let encoded = try? JSONEncoder().encode(payload) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        request.httpBody = encoded

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
    }
}
