import Foundation
import GRDB
import Testing
@testable import SignalBarCore

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
        session: RecordingSSHSession
    ) -> RemoteConnectionService {
        RemoteConnectionService(repo: repo) { _, _ in
            session.note("connect")
            return session
        }
    }

    @Test func returnsTheTrimmedWhoamiOutput() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSSHSession(results: [.success(SSHCommandResult(exitCode: 0, stdout: "  deploy \n", stderr: ""))])

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
        let session = RecordingSSHSession(fingerprint: "fingerprint-1")

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

        let session = RecordingSSHSession(fingerprint: "different")
        _ = try await service(repo, session: session).testConnection(pinned)

        #expect(try repo.get(id: server.id!)?.hostKeyFingerprint == "original")
    }

    @Test func aNonZeroExitBecomesCommandFailedCarryingStderr() async throws {
        let repo = try makeRepo()
        let server = try addServer(repo)
        let session = RecordingSSHSession(results: [.success(SSHCommandResult(exitCode: 127, stdout: "", stderr: "not found"))])

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

        _ = try await service(repo, session: RecordingSSHSession()).testConnection(server)
        #expect(try repo.recentLog(serverId: server.id!).count == 1)

        let failing = RecordingSSHSession(results: [.failure(SSHCommandRunnerError.timedOut(seconds: 30))])
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
        let session = RecordingSSHSession(results: [.failure(SSHCommandRunnerError.timedOut(seconds: 30))])

        await #expect(throws: SSHCommandRunnerError.timedOut(seconds: 30)) {
            try await service(repo, session: session).testConnection(server)
        }
        #expect(session.log.contains("close"))
    }
}
