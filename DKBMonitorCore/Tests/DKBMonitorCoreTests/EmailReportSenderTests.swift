import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

/// Records every request the sender makes and answers with whatever the test
/// queued. `URLProtocol` is the only seam that sees the request exactly as it
/// goes on the wire, which is the point: these assert the wire contract, not
/// the Swift call.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [(url: URL, headers: [String: String], body: Data)] = []
    nonisolated(unsafe) private static var _response: (status: Int, body: Data) = (200, Data("{}".utf8))

    static var requests: [(url: URL, headers: [String: String], body: Data)] {
        lock.withLock { _requests }
    }

    static func reset(status: Int = 200, body: String = "{}") {
        lock.withLock {
            _requests = []
            _response = (status, Data(body.utf8))
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` moves the body to `httpBodyStream`, so reading
        // `httpBody` here would silently see nil for every POST.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer[0..<read])
            }
        } else if let raw = request.httpBody {
            body = raw
        }

        let queued = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self._requests.append((request.url!, request.allHTTPHeaderFields ?? [:], body))
            return Self._response
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: queued.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: queued.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class InMemoryRelayTokenStore: EmailRelayTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(token: String? = nil) { self.stored = token }

    func token() -> String? { lock.withLock { stored } }
    func save(_ token: String) throws { lock.withLock { stored = token } }
    func clear() throws { lock.withLock { stored = nil } }
}

/// Serialized because `URLProtocol` subclasses are instantiated by
/// `URLSession` itself, so the queued response and the recorded requests have
/// to live in statics — run in parallel, these tests read each other's
/// traffic.
@Suite(.serialized) struct EmailReportSenderTests {
    private func makeSender(token: String? = nil) throws -> (EmailReportSender, InMemoryRelayTokenStore, AppDatabase) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let store = InMemoryRelayTokenStore(token: token)
        let sender = EmailReportSender(dbQueue: app.dbQueue, tokenStore: store, session: StubURLProtocol.makeSession())
        return (sender, store, app)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - The property that matters

    /// The relay decides the recipient from the token. If the app ever sent
    /// one, a future server that trusted it would reopen the hole.
    @Test func aSendNamesNoRecipient() async throws {
        StubURLProtocol.reset(body: #"{"sent":true}"#)
        let (sender, _, _) = try makeSender(token: "tok_abc")

        _ = await sender.send(subject: "S", body: "B")

        let request = try #require(StubURLProtocol.requests.first)
        let payload = json(request.body)
        #expect(payload["subject"] as? String == "S")
        #expect(payload["body"] as? String == "B")
        #expect(payload["recipientEmail"] == nil)
        #expect(payload.count == 2)
    }

    @Test func aSendCarriesTheTokenAsABearerHeader() async throws {
        StubURLProtocol.reset(body: #"{"sent":true}"#)
        let (sender, _, _) = try makeSender(token: "tok_abc")

        _ = await sender.send(subject: "S", body: "B")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.headers["Authorization"] == "Bearer tok_abc")
        #expect(request.url.path == "/api/dkb-monitor/notify")
    }

    /// Not merely "returns false": an unverified install must not generate
    /// traffic at all, since the endpoint would reject it anyway.
    @Test func withoutATokenNothingIsSent() async throws {
        StubURLProtocol.reset()
        let (sender, _, _) = try makeSender(token: nil)

        let failure = await sender.send(subject: "S", body: "B")

        #expect(failure == .notVerified)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    /// A 401 means the relay no longer knows this token — its database was
    /// reset, or the row was revoked — and nothing on this Mac can change
    /// that. Keeping the local half would leave Settings saying "Verified"
    /// and the scheduler retrying twice an hour, forever.
    @Test func aRefusedTokenIsDroppedSoTheUserIsAskedToVerifyAgain() async throws {
        StubURLProtocol.reset(status: 401, body: "")
        let (sender, store, app) = try makeSender(token: "stale_token")
        try SettingsRepository(dbQueue: app.dbQueue).update({
            var s = AppSettings.defaults
            s.smtpRecipientEmail = "owner@example.com"
            s.smtpVerifiedEmail = "owner@example.com"
            return s
        }())

        let failure = await sender.send(subject: "S", body: "B")

        #expect(failure == .notVerified)
        #expect(store.token() == nil)
        #expect(try SettingsRepository(dbQueue: app.dbQueue).load().smtpVerifiedEmail.isEmpty)
    }

    /// The three answers a user needs to tell apart: verify again, fix the
    /// message, or just wait. A bare "failed" is how a wrong relay host went
    /// unnoticed for months.
    @Test func eachKindOfFailureIsReportedAsItself() async throws {
        StubURLProtocol.reset(status: 503, body: "")
        var (sender, _, _) = try makeSender(token: "tok")
        #expect(await sender.send(subject: "S", body: "B") == .network)

        StubURLProtocol.reset(status: 400, body: "")
        (sender, _, _) = try makeSender(token: "tok")
        #expect(await sender.send(subject: "S", body: "B") == .rejected(status: 400))

        StubURLProtocol.reset(status: 429, body: "")
        (sender, _, _) = try makeSender(token: "tok")
        #expect(await sender.send(subject: "S", body: "B") == .rateLimited)

        StubURLProtocol.reset(body: #"{"sent":false}"#)
        (sender, _, _) = try makeSender(token: "tok")
        #expect(await sender.send(subject: "S", body: "B") == .notDelivered)

        StubURLProtocol.reset(body: #"{"sent":true}"#)
        (sender, _, _) = try makeSender(token: "tok")
        #expect(await sender.send(subject: "S", body: "B") == nil)
    }

    /// A relay that is down must not be reported as the user having typed
    /// the wrong code — that sends them off to request another one from a
    /// server that cannot answer.
    @Test func aServerErrorDuringConfirmIsNotBlamedOnTheCode() async throws {
        StubURLProtocol.reset(status: 503, body: "")
        let (sender, store, _) = try makeSender()

        await #expect(throws: EmailRelayError.network) {
            try await sender.confirmVerification(email: "owner@example.com", code: "123456")
        }
        #expect(store.token() == nil)
    }

    // MARK: - Verification

    @Test func confirmingStoresTheTokenAndTheAddressItBelongsTo() async throws {
        StubURLProtocol.reset(body: #"{"token":"tok_new","email":"owner@example.com"}"#)
        let (sender, store, app) = try makeSender()

        try await sender.confirmVerification(email: "owner@example.com", code: "123456")

        #expect(store.token() == "tok_new")
        #expect(try SettingsRepository(dbQueue: app.dbQueue).load().smtpVerifiedEmail == "owner@example.com")
    }

    /// The address is taken from the relay's answer, not from what was typed
    /// — they are the same today, and pinning it stops a later edit from
    /// making the app claim an address the token does not cover.
    @Test func theVerifiedAddressComesFromTheServer() async throws {
        StubURLProtocol.reset(body: #"{"token":"tok_new","email":"canonical@example.com"}"#)
        let (sender, _, app) = try makeSender()

        try await sender.confirmVerification(email: "TYPED@example.com", code: "123456")

        #expect(try SettingsRepository(dbQueue: app.dbQueue).load().smtpVerifiedEmail == "canonical@example.com")
    }

    @Test func aWrongCodeLeavesTheInstallUnverified() async throws {
        StubURLProtocol.reset(status: 400, body: #"{"error":"invalid_or_expired_code"}"#)
        let (sender, store, app) = try makeSender()

        await #expect(throws: EmailRelayError.invalidOrExpiredCode) {
            try await sender.confirmVerification(email: "owner@example.com", code: "000000")
        }
        #expect(store.token() == nil)
        #expect(try SettingsRepository(dbQueue: app.dbQueue).load().smtpVerifiedEmail.isEmpty)
    }

    /// Being rate-limited is worth telling apart from a wrong code: one says
    /// try again, the other says wait.
    @Test func beingRateLimitedIsItsOwnError() async throws {
        StubURLProtocol.reset(status: 429, body: "")
        let (sender, _, _) = try makeSender()

        await #expect(throws: EmailRelayError.rateLimited) {
            try await sender.confirmVerification(email: "owner@example.com", code: "123456")
        }
    }

    @Test func startingVerificationPostsTheAddressAndNothingElse() async throws {
        StubURLProtocol.reset(status: 202, body: "")
        let (sender, _, _) = try makeSender()

        #expect(await sender.startVerification(email: "owner@example.com"))

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url.path == "/api/dkb-monitor/verify/start")
        #expect(json(request.body)["email"] as? String == "owner@example.com")
    }

    @Test func forgettingClearsBothTheTokenAndTheRecordedAddress() async throws {
        StubURLProtocol.reset(body: #"{"token":"tok_new","email":"owner@example.com"}"#)
        let (sender, store, app) = try makeSender()
        try await sender.confirmVerification(email: "owner@example.com", code: "123456")

        try sender.forgetVerification()

        #expect(store.token() == nil)
        #expect(try SettingsRepository(dbQueue: app.dbQueue).load().smtpVerifiedEmail.isEmpty)
    }
}
