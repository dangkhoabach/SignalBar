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

        // Wrapped so any failure after this point (recording the host key,
        // running `whoami`) still closes the connection instead of leaking
        // it — the earlier version only closed on the success path.
        do {
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
        } catch let error as SSHCommandRunnerError {
            // `commandFailed`, thrown by the `guard` above — the connection
            // was already closed and the attempt already logged (with the
            // real stderr) a few lines up, so just propagate it.
            throw error
        } catch {
            // Everything before `run` returned a result (host key
            // recording, or `run` itself throwing) skipped the close+log
            // above entirely — do both here so this path isn't silently
            // unaudited and the connection isn't leaked.
            try? await connection.close()
            if let id = server.id {
                try? repo.logCommand(serverId: id, action: "testConnection", exitCode: nil, outputExcerpt: String(String(describing: error).prefix(500)))
            }
            throw error
        }
    }
}
