import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

/// Covers running several actions over one session — the handshake cost the
/// detail pane's Refresh used to pay five times over.
@Suite struct RemoteCommandExecutorBatchTests {
    private func makeServer() throws -> (RemoteServerRepository, RemoteServer) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore())
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "127.0.0.1", port: 22, username: "deploy", credential: .password("s3cr3t")
        ))
        return (repo, server)
    }

    private func executor(
        _ repo: RemoteServerRepository,
        session: RecordingSSHSession,
        onConnect: (@Sendable () -> Void)? = nil
    ) -> RemoteCommandExecutor {
        RemoteCommandExecutor(repo: repo) { _, _ in
            session.note("connect")
            onConnect?()
            return session
        }
    }

    private func statsSession(
        disk: String = "Filesystem Size Used Avail Use% Mounted\n/dev/sda1 20G 8.0G 11G 43% /",
        memory: String = "              total        used        free      shared  buff/cache   available\nMem:           7976        2100        3000         100        2876        5500\nSwap:          2047         100        1947",
        uptime: String = " 10:00:00 up 3 days,  2:11,  1 user,  load average: 0.10, 0.20, 0.30",
        cpu: String = "%Cpu(s):  7.4 us,  2.1 sy,  0.0 ni, 89.5 id,  0.6 wa,  0.0 hi,  0.4 si,  0.0 st",
        os: String = "Linux 5.15.0-91-generic\nPRETTY_NAME=\"Ubuntu 22.04.3 LTS\""
    ) -> RecordingSSHSession {
        RecordingSSHSession(results: [disk, memory, uptime, cpu, os].map {
            .success(SSHCommandResult(exitCode: 0, stdout: $0, stderr: ""))
        })
    }

    /// The point of the whole change: five readings, one handshake.
    @Test func allFiveStatsRunOverASingleSession() async throws {
        let (repo, server) = try makeServer()
        let session = statsSession()
        let connects = Counter()

        _ = try await executor(repo, session: session, onConnect: { connects.increment() }).stats(on: server)

        #expect(connects.value == 1)
        #expect(session.log.filter { $0.hasPrefix("run:") }.count == 5)
        #expect(session.log.last == "close")
    }

    @Test func statsParsesEveryReading() async throws {
        let (repo, server) = try makeServer()
        let stats = try await executor(repo, session: statsSession()).stats(on: server)

        #expect(stats.failures.isEmpty)
        #expect(stats.disk?.usePercent == "43%")
        #expect(stats.memory?.totalMB == 7976)
        #expect(stats.uptime?.loadAverages == [0.10, 0.20, 0.30])
        #expect(stats.cpu != nil)
        #expect(stats.os?.prettyName == "Ubuntu 22.04.3 LTS")
    }

    /// The reason results come back per action instead of throwing: a box
    /// without `top` should still report its disk and memory. The old code
    /// discarded already-fetched readings when any one of them threw.
    @Test func oneFailedCommandDoesNotDiscardTheOthers() async throws {
        let (repo, server) = try makeServer()
        let session = RecordingSSHSession(results: [
            .success(SSHCommandResult(exitCode: 0, stdout: "Filesystem Size Used Avail Use% Mounted\n/dev/sda1 20G 8.0G 11G 43% /", stderr: "")),
            .success(SSHCommandResult(exitCode: 0, stdout: "              total        used        free      shared  buff/cache   available\nMem:           7976        2100        3000         100        2876        5500", stderr: "")),
            .success(SSHCommandResult(exitCode: 0, stdout: " 10:00:00 up 3 days,  2:11,  1 user,  load average: 0.10, 0.20, 0.30", stderr: "")),
            .failure(SSHCommandRunnerError.timedOut(seconds: 30)),
            .success(SSHCommandResult(exitCode: 0, stdout: "Linux 5.15.0-91-generic", stderr: "")),
        ])

        let stats = try await executor(repo, session: session).stats(on: server)

        #expect(stats.disk != nil)
        #expect(stats.memory != nil)
        #expect(stats.uptime != nil)
        #expect(stats.os != nil)
        #expect(stats.cpu == nil)
        #expect(stats.failures.count == 1)
        #expect(stats.failures[0].hasPrefix("cpuUsage:"))
    }

    /// A command that ran but returned something unparseable leaves the pane
    /// just as empty as one that never ran, so it has to be reported too.
    @Test func unparseableOutputIsReportedRatherThanSilentlyDropped() async throws {
        let (repo, server) = try makeServer()
        let session = RecordingSSHSession(results: [
            .success(SSHCommandResult(exitCode: 0, stdout: "not df output at all", stderr: "")),
        ], defaultResult: .success(SSHCommandResult(exitCode: 0, stdout: "", stderr: "")))

        let stats = try await executor(repo, session: session).stats(on: server)

        #expect(stats.disk == nil)
        #expect(stats.failures.contains { $0.hasPrefix("diskUsage:") })
    }

    /// Authorization is per action and happens before anything connects, so
    /// an unauthorized member rejects the batch without opening a session.
    @Test func anUnauthorizedActionStopsTheBatchBeforeConnecting() async throws {
        let (repo, server) = try makeServer()
        let session = statsSession()
        let connects = Counter()
        let executor = executor(repo, session: session, onConnect: { connects.increment() })

        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("nginx")) {
            try await executor.execute([.diskUsage, .serviceRestart(name: "nginx")], on: server)
        }
        #expect(connects.value == 0)
        #expect(session.log.isEmpty)
    }

    @Test func everyCommandInTheBatchIsWrittenToTheAuditLog() async throws {
        let (repo, server) = try makeServer()
        _ = try await executor(repo, session: statsSession()).stats(on: server)

        let logged = try repo.recentLog(serverId: server.id!).map(\.action)
        #expect(Set(logged) == ["diskUsage", "memoryUsage", "uptime", "cpuUsage", "osInfo"])
    }

    @Test func anEmptyBatchNeverConnects() async throws {
        let (repo, server) = try makeServer()
        let session = statsSession()
        let connects = Counter()

        let results = try await executor(repo, session: session, onConnect: { connects.increment() })
            .execute([], on: server)

        #expect(results.isEmpty)
        #expect(connects.value == 0)
    }
}

/// The connector closure is `@Sendable`, so a plain `var` can't be counted
/// from inside it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
