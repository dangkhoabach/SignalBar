import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

/// Bulk running adds no capability — it fans one already-allowlisted action
/// out across servers. These pin the two things that makes non-obvious: each
/// server's own allowlist still decides, and one bad server cannot take the
/// run down with it.
@Suite struct RemoteBulkExecutorTests {
    private func makeRepo() throws -> (RemoteServerRepository, AppDatabase) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return (RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore()), app)
    }

    @discardableResult
    private func addServer(
        _ repo: RemoteServerRepository, name: String, allowService: String? = "nginx"
    ) throws -> RemoteServer {
        let server = try repo.add(NewRemoteServerInput(
            name: name, host: "10.0.0.1", port: 22, username: "deploy", credential: .password("s3cr3t")
        ))
        if let allowService {
            try repo.addAllowlistEntry(serverId: server.id!, kind: .service, value: allowService)
        }
        return server
    }

    private func bulk(
        _ repo: RemoteServerRepository,
        sessionFor: @escaping @Sendable (RemoteServer) -> RecordingSSHSession
    ) -> RemoteBulkExecutor {
        RemoteBulkExecutor(executor: RemoteCommandExecutor(repo: repo) { server, _ in sessionFor(server) })
    }

    private func okSession() -> RecordingSSHSession {
        RecordingSSHSession(defaultResult: .success(SSHCommandResult(exitCode: 0, stdout: "ok\n", stderr: "")))
    }

    @Test func everySelectedServerGetsTheAction() async throws {
        let (repo, _) = try makeRepo()
        let servers = try ["a", "b", "c"].map { try addServer(repo, name: $0) }
        let sessions = LockBox<[Int64: RecordingSSHSession]>([:])

        let outcomes = await bulk(repo) { server in
            let session = RecordingSSHSession(defaultResult: .success(SSHCommandResult(exitCode: 0, stdout: "ok", stderr: "")))
            sessions.withLock { $0[server.id!] = session }
            return session
        }.run(.serviceRestart(name: "nginx"), on: servers)

        let allSucceeded = outcomes.allSatisfy(\.succeeded)
        let sessionCount = sessions.withLock { $0.count }
        #expect(outcomes.count == 3)
        #expect(allSucceeded)
        #expect(sessionCount == 3)
    }

    /// The results table must not reshuffle itself according to which server
    /// happened to answer first.
    @Test func resultsComeBackInTheOrderTheServersWereGiven() async throws {
        let (repo, _) = try makeRepo()
        let servers = try ["alpha", "beta", "gamma", "delta"].map { try addServer(repo, name: $0) }

        let outcomes = await bulk(repo) { _ in self.okSession() }
            .run(.serviceRestart(name: "nginx"), on: servers)

        #expect(outcomes.map(\.serverName) == ["alpha", "beta", "gamma", "delta"])
    }

    /// The heart of it: a server that never allowlisted this action is
    /// refused *there*, and the others still run.
    @Test func aServerWithoutTheActionAllowlistedFailsAlone() async throws {
        let (repo, _) = try makeRepo()
        let allowed = try addServer(repo, name: "allowed", allowService: "nginx")
        let notAllowed = try addServer(repo, name: "not-allowed", allowService: nil)

        let outcomes = await bulk(repo) { _ in self.okSession() }
            .run(.serviceRestart(name: "nginx"), on: [allowed, notAllowed])

        #expect(outcomes.first(where: { $0.serverName == "allowed" })?.succeeded == true)
        #expect(outcomes.first(where: { $0.serverName == "not-allowed" })?.succeeded == false)
    }

    /// An unreachable box is the ordinary case in a fleet, not an abort
    /// condition.
    @Test func oneUnreachableServerDoesNotStopTheRest() async throws {
        let (repo, _) = try makeRepo()
        let good = try addServer(repo, name: "good")
        let bad = try addServer(repo, name: "bad")

        let outcomes = await RemoteBulkExecutor(
            executor: RemoteCommandExecutor(repo: repo) { server, _ in
                if server.name == "bad" { throw SSHCommandRunnerError.timedOut(seconds: 5) }
                return RecordingSSHSession(defaultResult: .success(SSHCommandResult(exitCode: 0, stdout: "ok", stderr: "")))
            }
        ).run(.serviceRestart(name: "nginx"), on: [good, bad])

        #expect(outcomes.count == 2)
        #expect(outcomes.first(where: { $0.serverName == "good" })?.succeeded == true)
        #expect(outcomes.first(where: { $0.serverName == "bad" })?.succeeded == false)
    }

    /// A non-zero exit is not a thrown error, and reporting it as success
    /// because "the command ran" would be the easy mistake here.
    @Test func aNonZeroExitCountsAsFailureAndKeepsItsStderr() async throws {
        let (repo, _) = try makeRepo()
        let server = try addServer(repo, name: "prod")

        let outcomes = await bulk(repo) { _ in
            RecordingSSHSession(defaultResult: .success(
                SSHCommandResult(exitCode: 3, stdout: "", stderr: "Unit nginx.service not found")
            ))
        }.run(.serviceRestart(name: "nginx"), on: [server])

        let outcome = try #require(outcomes.first)
        #expect(outcome.succeeded == false)
        #expect(outcome.summary.contains("Unit nginx.service not found"))
        #expect(outcome.summary.contains("3"))
    }

    @Test func anEmptySelectionRunsNothing() async throws {
        let (repo, _) = try makeRepo()
        let outcomes = await bulk(repo) { _ in self.okSession() }.run(.uptime, on: [])
        #expect(outcomes.isEmpty)
    }

    /// Unsaved servers have no id to report against and no allowlist rows, so
    /// they are dropped rather than crashing on `server.id!`.
    @Test func anUnsavedServerIsSkipped() async throws {
        let (repo, _) = try makeRepo()
        let saved = try addServer(repo, name: "saved")
        let unsaved = RemoteServer(
            name: "unsaved", host: "10.0.0.9", username: "deploy",
            authMethod: .password, keychainRef: "nope"
        )

        let outcomes = await bulk(repo) { _ in self.okSession() }
            .run(.serviceRestart(name: "nginx"), on: [saved, unsaved])

        #expect(outcomes.map(\.serverName) == ["saved"])
    }

    /// More servers than the concurrency cap must still all run — the cap
    /// paces the work, it does not truncate it.
    @Test func moreServersThanTheConcurrencyCapAllRun() async throws {
        let (repo, _) = try makeRepo()
        let count = RemoteBulkExecutor.maxConcurrent + 3
        let servers = try (0..<count).map { try addServer(repo, name: "s\($0)") }

        let outcomes = await bulk(repo) { _ in self.okSession() }
            .run(.serviceRestart(name: "nginx"), on: servers)

        let allSucceeded = outcomes.allSatisfy(\.succeeded)
        #expect(outcomes.count == count)
        #expect(allSucceeded)
    }
}

/// Minimal lock box — the fake session factory is `@Sendable`, so it cannot
/// capture a plain `var`.
final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
