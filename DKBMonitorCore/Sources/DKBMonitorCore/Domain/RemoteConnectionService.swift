import Foundation

/// Phase 0's only orchestration: connect, pin the host key on first contact,
/// run one harmless command (`whoami`) to prove the credential works. Later
/// phases' allowlisted actions (service restart, nginx reload, log tail...)
/// go through `RemoteCommandExecutor` instead, which will depend on this same
/// connect-and-pin step.
public struct RemoteConnectionService: Sendable {
    private let repo: RemoteServerRepository

    public init(repo: RemoteServerRepository) {
        self.repo = repo
    }

    @discardableResult
    public func testConnection(_ server: RemoteServer) async throws -> String {
        let credential = try repo.credential(for: server, forMutatingAction: false)
        let connection = try await SSHCommandRunner.connect(
            host: server.host,
            port: server.port,
            username: server.username,
            credential: credential,
            pinnedHostKeyFingerprint: server.hostKeyFingerprint
        )

        if server.hostKeyFingerprint == nil, let id = server.id {
            try repo.recordHostKeyFingerprint(id: id, fingerprint: connection.hostKeyFingerprint)
        }

        let result = try await connection.run("whoami")
        try? await connection.close()

        if let id = server.id {
            try? repo.logCommand(
                serverId: id, action: "testConnection",
                exitCode: result.exitCode,
                outputExcerpt: String((result.succeeded ? result.stdout : result.stderr).prefix(500))
            )
        }

        guard result.succeeded else {
            throw SSHCommandRunnerError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
