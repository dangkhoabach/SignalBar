import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

/// Records what happened to a session and in what order, so the sequence
/// `testConnection` performs can be asserted rather than assumed.
private final class RecordingSession: SSHSession, @unchecked Sendable {
    let hostKeyFingerprint: String
    private let result: SSHCommandResult?
    private let failure: Error?
    private let lock = NSLock()
    private var events: [String] = []

    init(fingerprint: String, result: SSHCommandResult? = nil, failure: Error? = nil) {
        self.hostKeyFingerprint = fingerprint
        self.result = result
        self.failure = failure
    }

    var log: [String] { lock.withLock { events } }

    func note(_ event: String) { lock.withLock { events.append(event) } }

    func run(_ command: String) async throws -> SSHCommandResult {
        note("run:\(command)")
        if let failure { throw failure }
        return result ?? SSHCommandResult(exitCode: 0, stdout: "deploy\n", stderr: "")
    }

    func close() async throws {
        note("close")
    }
}

@Suite struct RemoteConnectionServiceTests {
    private func makeRepo() throws -> RemoteServerRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore())
    }

    private func addServer(_ repo: RemoteServerRepository) throws -> RemoteServer {
        try repo.add(NewRemoteServerInput(
            name: "Prod", host: "127.0.0.1", port: 22, username: "deploy", credential: .password("s3cr3t")
        ))
    }

    private func service(
        _ repo: RemoteServerRepository,
        session: RecordingSession
    ) -> RemoteConnectionService {
        RemoteConnectionService(repo: repo) { _, _ in
            session.note("connect")
            return session
        }
    }

    @Test func returnsTheTrimmedWhoamiOutput() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSession(fingerprint: "abc123", result: SSHCommandResult(exitCode: 0, stdout: "  deploy \n", stderr: ""))

        let whoami = try await service(repo, session: session).testConnection(server)
        #expect(whoami == "deploy")
    }

    /// The order that matters: the fingerprint is written the moment the
    /// handshake completes, before a single command is sent. A command sent
    /// first would have already run against an unverified host by the time
    /// anything was recorded.
    @Test func theHostKeyIsPinnedBeforeAnyCommandRuns() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSession(fingerprint: "fingerprint-1")

        _ = try await service(repo, session: session).testConnection(server)

        #expect(session.log == ["connect", "run:whoami", "close"])
        #expect(try repo.get(id: server.id!)?.hostKeyFingerprint == "fingerprint-1")
    }

    /// A server that already has a pinned key must not have it overwritten
    /// here — re-pinning on every connect would turn a genuine key change
    /// (the MITM signal) into a silent update.
    @Test func anAlreadyPinnedFingerprintIsNotRewritten() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        try repo.recordHostKeyFingerprint(id: server.id!, fingerprint: "original")
        let pinned = try #require(try repo.get(id: server.id!))

        let session = RecordingSession(fingerprint: "different")
        _ = try await service(repo, session: session).testConnection(pinned)

        #expect(try repo.get(id: server.id!)?.hostKeyFingerprint == "original")
    }

    @Test func aNonZeroExitBecomesCommandFailedCarryingStderr() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSession(fingerprint: "abc", result: SSHCommandResult(exitCode: 127, stdout: "", stderr: "not found"))

        await #expect(throws: SSHCommandRunnerError.commandFailed(exitCode: 127, stderr: "not found")) {
            try await service(repo, session: session).testConnection(server)
        }
    }

    /// Every attempt is auditable, including the ones that failed — a
    /// command log with only successes in it is the one that can't answer
    /// "what happened last night".
    @Test func bothSuccessAndFailureAreWrittenToTheCommandLog() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)

        _ = try await service(repo, session: RecordingSession(fingerprint: "abc")).testConnection(server)
        #expect(try repo.recentLog(serverId: server.id!).count == 1)

        let failing = RecordingSession(fingerprint: "abc", failure: SSHCommandRunnerError.timedOut(seconds: 30))
        _ = try? await service(repo, session: failing).testConnection(server)

        let log = try repo.recentLog(serverId: server.id!)
        #expect(log.count == 2)
        #expect(log.allSatisfy { $0.action == "testConnection" })
    }

    /// Whatever goes wrong after the handshake, the session gets closed —
    /// an earlier version only closed on the success path, leaking one
    /// connection per failed attempt.
    @Test func theSessionIsClosedEvenWhenTheCommandThrows() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSession(fingerprint: "abc", failure: SSHCommandRunnerError.timedOut(seconds: 30))

        await #expect(throws: SSHCommandRunnerError.timedOut(seconds: 30)) {
            try await service(repo, session: session).testConnection(server)
        }
        #expect(session.log.contains("close"))
    }
}
