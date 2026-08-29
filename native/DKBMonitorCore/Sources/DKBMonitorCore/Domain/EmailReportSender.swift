import Foundation
import GRDB

/// Sends periodic reports through this app's own backend relay rather than
/// any user-supplied SMTP account — no email credential of any kind is ever
/// stored in or shipped with this app. Ports `mail.rs::send_email_via_relay`,
/// keeping the exact same JSON contract (`recipientEmail`/`subject`/`body`
/// request, `{"sent": bool}` response) since the server side isn't changing.
public struct EmailReportSender: ReportSending {
    private static let endpoint = URL(string: "https://admin.dangkhoabach.vn/api/dkb-monitor/notify")!

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func sendReport(label: String, days: Int) async -> Bool {
        guard let recipient = try? SettingsRepository(dbQueue: dbQueue).load().smtpRecipientEmail, !recipient.isEmpty else {
            return false
        }
        guard let body = try? ReportGenerator.generate(dbQueue: dbQueue, label: label, days: days) else {
            return false
        }
        return await Self.sendViaRelay(recipientEmail: recipient, subject: "DKB Monitor — \(label) Report", body: body)
    }

    private struct RelayRequest: Encodable {
        let recipientEmail: String
        let subject: String
        let body: String
    }

    private struct RelayResponse: Decodable {
        let sent: Bool
    }

    static func sendViaRelay(recipientEmail: String, subject: String, body: String) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RelayRequest(recipientEmail: recipientEmail, subject: subject, body: body))

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(RelayResponse.self, from: data)
        else {
            return false
        }
        return decoded.sent
    }
}
