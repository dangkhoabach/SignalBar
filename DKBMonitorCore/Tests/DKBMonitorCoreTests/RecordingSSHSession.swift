import Foundation
@testable import DKBMonitorCore

/// Stands in for a live SSH session and records what was asked of it, in
/// order, so tests can assert the sequence a caller performs — and, for a
/// batch, that everything ran on one session rather than several.
final class RecordingSSHSession: SSHSession, @unchecked Sendable {
    let hostKeyFingerprint: String

    /// Answers for `run`, consumed in order; once exhausted, `defaultResult`
    /// is returned. An entry can be a failure, which is how a batch with one
    /// bad command among good ones is set up.
    private var scriptedResults: [Result<SSHCommandResult, any Error>]
    private let defaultResult: Result<SSHCommandResult, any Error>

    private let lock = NSLock()
    private var events: [String] = []

    init(
        fingerprint: String = "abc123",
        results: [Result<SSHCommandResult, any Error>] = [],
        defaultResult: Result<SSHCommandResult, any Error> = .success(SSHCommandResult(exitCode: 0, stdout: "ok\n", stderr: ""))
    ) {
        self.hostKeyFingerprint = fingerprint
        self.scriptedResults = results
        self.defaultResult = defaultResult
    }

    var log: [String] { lock.withLock { events } }

    func note(_ event: String) { lock.withLock { events.append(event) } }

    func run(_ command: String) async throws -> SSHCommandResult {
        note("run:\(command)")
        let next: Result<SSHCommandResult, any Error> = lock.withLock {
            scriptedResults.isEmpty ? defaultResult : scriptedResults.removeFirst()
        }
        return try next.get()
    }

    func readFile(_ path: String) async throws -> String {
        note("readFile:\(path)")
        return ""
    }

    func writeFile(_ path: String, content: String) async throws {
        note("writeFile:\(path)")
    }

    func close() async throws {
        note("close")
    }
}
