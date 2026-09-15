import Foundation
import GRDB

public enum EmailRelayError: Error, Sendable, Equatable {
    /// No token on this install yet, or the one it has was revoked.
    case notVerified
    case invalidOrExpiredCode
    case rateLimited
    case network
}

extension EmailRelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notVerified:
            "This Mac has not been verified to receive reports at that address yet."
        case .invalidOrExpiredCode:
            "That code is wrong or has expired. Ask for a new one."
        case .rateLimited:
            "Too many attempts. Wait a while before trying again."
        case .network:
            "Could not reach admin.dangkhoabach.vn."
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
    private static let baseURL = URL(string: "https://admin.dangkhoabach.vn/api/dkb-monitor")!

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
            throw http.statusCode == 429 ? EmailRelayError.rateLimited : EmailRelayError.invalidOrExpiredCode
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
        return await send(subject: "DKB Monitor — \(label) Report", body: body)
    }

    public func sendTestEmail() async -> Bool {
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

    func send(subject: String, body: String) async -> Bool {
        guard let token = tokenStore.token() else { return false }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("notify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RelayRequest(subject: subject, body: body))

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(RelayResponse.self, from: data)
        else {
            return false
        }
        return decoded.sent
    }
}
