import Foundation

/// Phase 0's only orchestration: connect, pin the host key on first contact,
/// run one harmless command (`whoami`) to prove the credential works. Later
/// phases' allowlisted actions (service restart, nginx reload, log tail...)
/// go through `RemoteCommandExecutor` instead, which will depend on this same
/// connect-and-pin step.
public struct RemoteConnectionService: Sendable {
    /// How a session is opened. Real connections always go through
    /// `SSHCommandRunner.connect`; the seam exists so tests can assert the
    /// order this type does things in — specifically that the host key is
    /// pinned before any command runs — without a live SSH daemon. Internal,
    /// so the public API is still just `init(repo:)`.
    typealias Connector = @Sendable (RemoteServer, SSHAuthCredential) async throws -> any SSHSession

    private let repo: RemoteServerRepository
    private let connect: Connector

    public init(repo: RemoteServerRepository) {
        self.init(repo: repo, connect: Self.liveConnector)
    }

    init(repo: RemoteServerRepository, connect: @escaping Connector) {
        self.repo = repo
        self.connect = connect
    }

    private static let liveConnector: Connector = { server, credential in
        try await SSHCommandRunner.connect(
            host: server.host,
            port: server.port,
            username: server.username,
            credential: credential,
            pinnedHostKeyFingerprint: server.hostKeyFingerprint
        )
    }

    @discardableResult
    public func testConnection(_ server: RemoteServer) async throws -> String {
        let credential = try repo.credential(for: server, forMutatingAction: false)
        let connection = try await connect(server, credential)

        // Only the part that can fail *before* there's a result to report is
        // wrapped. An earlier version wrapped the whole body and told the
        // two cases apart by error type — treating any `SSHCommandRunnerError`
        // as "already closed and logged", which was true only of the
        // `commandFailed` raised a few lines down. Once `run` gained its own
        // operation timeout, a timed-out `whoami` took that same branch and
        // left the connection open and the attempt unlogged. Splitting the
        // paths means neither one can be reached by an error it wasn't
        // written for.
        let result: SSHCommandResult
        do {
            if server.hostKeyFingerprint == nil, let id = server.id {
                try repo.recordHostKeyFingerprint(id: id, fingerprint: connection.hostKeyFingerprint)
            }
            result = try await connection.run("whoami")
        } catch {
            try? await connection.close()
            log(server: server, exitCode: nil, excerpt: String(describing: error))
            throw error
        }

        try? await connection.close()
        log(
            server: server,
            exitCode: result.exitCode,
            excerpt: result.succeeded ? result.stdout : result.stderr
        )

        guard result.succeeded else {
            throw SSHCommandRunnerError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort by design: losing the audit line is not a reason to fail
    /// a connection that otherwise worked.
    private func log(server: RemoteServer, exitCode: Int?, excerpt: String) {
        guard let id = server.id else { return }
        try? repo.logCommand(
            serverId: id, action: "testConnection",
            exitCode: exitCode, outputExcerpt: String(excerpt.prefix(500))
        )
    }
}
