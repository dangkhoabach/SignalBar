import Foundation
import GRDB

public enum EmailRelayError: Error, Sendable, Equatable {
    /// No token on this install yet, or the relay no longer accepts the one
    /// it has.
    case notVerified
    case invalidOrExpiredCode
    case rateLimited
    /// The relay refused the message itself — a 4xx other than the ones
    /// above, such as a subject over its length limit.
    case rejected(status: Int)
    /// Accepted by the relay, but the mail provider behind it failed.
    case notDelivered
    /// Unreachable, or answering with a 5xx — either way, not this Mac's
    /// doing and worth retrying later.
    case network
}

extension EmailRelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notVerified:
            "This Mac is not verified to receive reports at that address. Verify it again."
        case .invalidOrExpiredCode:
            "That code is wrong or has expired. Ask for a new one."
        case .rateLimited:
            "Too many attempts. Wait a while before trying again."
        case .rejected(let status):
            "The relay rejected the message (HTTP \(status))."
        case .notDelivered:
            "The relay accepted the message but could not deliver it."
        case .network:
            "Could not reach api.dangkhoabach.vn, or it is having trouble. Try again later."
        }
    }
}

/// Sends periodic reports through this app's own backend relay rather than
/// any user-supplied SMTP account — no email credential of any kind is ever
/// stored in or shipped with this app.
///
/// The relay takes **no recipient**. It reads one from this install's bearer
/// token, which is only issued to someone who read a code out of that
/// mailbox, so the address reports can reach is not something this app — or
/// anybody who found the endpoint in the binary — gets to choose. Before
/// that, `recipientEmail` was a free field on an unauthenticated endpoint,
/// which made it an open relay for the owner's domain.
public struct EmailReportSender: ReportSending {
    /// `api.dangkhoabach.vn`, not `admin.` — the admin host is a Next.js panel
    /// with no API on it. Pointing here at `admin.` was inherited from the
    /// Tauri build and carried through the port unchanged; that host answers
    /// this path with a 307 to its login page, which `URLSession` follows to
    /// a 200 and an HTML body, so every send failed its JSON decode and
    /// returned false. Confirmed against production on 2026-09-15.
    private static let baseURL = URL(string: "https://api.dangkhoabach.vn/api/dkb-monitor")!

    private let dbQueue: DatabaseQueue
    private let tokenStore: any EmailRelayTokenStoring
    private let session: URLSession

    public init(dbQueue: DatabaseQueue) {
        self.init(dbQueue: dbQueue, tokenStore: KeychainEmailRelayTokenStore(), session: .shared)
    }

    /// Internal seam: lets the tests drive the HTTP contract and the token
    /// store without a network or a signed process. The public API stays
    /// `init(dbQueue:)`.
    init(dbQueue: DatabaseQueue, tokenStore: any EmailRelayTokenStoring, session: URLSession) {
        self.dbQueue = dbQueue
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: - Verification

    /// Asks the relay to mail a code to `email`. Answers only whether the
    /// request was accepted — deliberately not whether mail arrived, which
    /// the server does not disclose.
    public func startVerification(email: String) async -> Bool {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("verify/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["email": email])

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return false
        }
        return (200...299).contains(http.statusCode)
    }

    /// Exchanges the code for this install's token and records which address
    /// it belongs to, so a later edit of the recipient field is visible as
    /// unverified rather than silently sending to the old address.
    public func confirmVerification(email: String, code: String) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("verify/confirm"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["email": email, "code": code])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            throw EmailRelayError.network
        }
        guard (200...299).contains(http.statusCode) else {
            // A 5xx here used to read as "wrong code" — the one answer that
            // sends the user off to request another code from a server that
            // is down.
            throw Self.relayError(status: http.statusCode, clientError: .invalidOrExpiredCode)
        }
        guard let decoded = try? JSONDecoder().decode(ConfirmResponse.self, from: data) else {
            throw EmailRelayError.network
        }

        try tokenStore.save(decoded.token)
        try await dbQueue.write { db in
            try AppSettingsStore.set(db, key: "smtp_verified_email", value: decoded.email)
        }
    }

    /// Drops this install's token. The row stays on the server, so the same
    /// address can be verified again without any cleanup there.
    public func forgetVerification() throws {
        try tokenStore.clear()
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "smtp_verified_email", value: "")
        }
    }

    // MARK: - Sending

    public func sendReport(label: String, days: Int) async -> Bool {
        guard let body = try? ReportGenerator.generate(dbQueue: dbQueue, label: label, days: days) else {
            return false
        }
        return await send(subject: "DKB Monitor — \(label) Report", body: body) == nil
    }

    /// Nil on success. The failure is returned, not swallowed into a Bool:
    /// a bare "failed" is exactly how a wrong relay host went unnoticed for
    /// months, and the difference between "not verified", "rejected" and
    /// "unreachable" is the difference between three different things the
    /// user should do next.
    public func sendTestEmail() async -> EmailRelayError? {
        await send(
            subject: "DKB Monitor — Test Email",
            body: "This is a test email from DKB Monitor to confirm your email report settings are working."
        )
    }

    private struct RelayRequest: Encodable {
        let subject: String
        let body: String
    }

    private struct RelayResponse: Decodable {
        let sent: Bool
    }

    private struct ConfirmResponse: Decodable {
        let token: String
        let email: String
    }

    func send(subject: String, body: String) async -> EmailRelayError? {
        guard let token = tokenStore.token() else { return .notVerified }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("notify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RelayRequest(subject: subject, body: body))

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return .network
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                // The relay no longer knows this token: its database was
                // reset, or the row was revoked. Nothing on this Mac can make
                // that succeed again, so the local half is dropped too — that
                // is what turns the Settings page from "Verified" to the
                // warning, and stops the scheduler retrying a send that can
                // never land.
                await revokeLocalVerification()
                return .notVerified
            }
            return Self.relayError(status: http.statusCode, clientError: .rejected(status: http.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(RelayResponse.self, from: data) else {
            return .network
        }
        return decoded.sent ? nil : .notDelivered
    }

    /// 429 and 5xx mean the same on every route; what another 4xx means
    /// depends on which route was called.
    private static func relayError(status: Int, clientError: EmailRelayError) -> EmailRelayError {
        switch status {
        case 429: .rateLimited
        case 500...599: .network
        default: clientError
        }
    }

    private func revokeLocalVerification() async {
        try? tokenStore.clear()
        try? await dbQueue.write { db in
            try AppSettingsStore.set(db, key: "smtp_verified_email", value: "")
        }
    }
}
