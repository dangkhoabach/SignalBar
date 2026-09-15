import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

public enum SSHAuthCredential: Sendable {
    case privateKey(pem: String, passphrase: String?)
    case password(String)
}

public enum SSHCommandRunnerError: Error, Sendable, Equatable {
    /// The host presented a different key than the one pinned on a previous
    /// connect — refused rather than silently trusting it, since this is
    /// exactly the signature of a MITM attack (see the plan's "Rủi ro kỹ
    /// thuật" section on SSH-key-in-the-Mac risk).
    case hostKeyMismatch
    case unsupportedPrivateKeyFormat(String)
    case commandFailed(exitCode: Int, stderr: String)
    /// Wraps whatever the underlying SSH/network layer threw while
    /// connecting (timeout, connection refused, auth rejected...) into one
    /// place with a message a user can act on, instead of leaking a raw
    /// NIO/Citadel error string — the retry itself is just re-tapping the
    /// same button (Test connection/Refresh), no dedicated retry UI needed.
    case connectionFailed(String)
    /// An operation that had already connected ran past its deadline.
    /// `connectTimeout` only covers the handshake, so without this a server
    /// that accepts the connection and then stops responding mid-command left
    /// the calling Task waiting with no way to get it back.
    case timedOut(seconds: Int)
}

extension SSHCommandRunnerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostKeyMismatch:
            "The server's SSH host key doesn't match the one recorded on your first connection. Refusing to connect — this can mean the server was reinstalled, or a man-in-the-middle attack."
        case .unsupportedPrivateKeyFormat(let type):
            "Unsupported private key format (\(type)). Only Ed25519 and RSA OpenSSH keys are supported."
        case .commandFailed(let exitCode, let stderr):
            "Command failed (exit code \(exitCode))\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .connectionFailed(let reason):
            "Couldn't connect to the server (\(reason)). Check the host, port, and that the server is reachable, then try again."
        case .timedOut(let seconds):
            "The server stopped responding after \(seconds) seconds. The connection was closed — check the server's load and try again."
        }
    }
}

public struct SSHCommandResult: Sendable, Equatable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// The part of a live session `RemoteConnectionService` actually uses.
///
/// Deliberately internal and deliberately small: it exists so the order in
/// which that service pins the host key and runs its first command can be
/// asserted without a live SSH daemon. `SSHConnection` is the only thing
/// that conforms in the app.
protocol SSHSession: Sendable {
    var hostKeyFingerprint: String { get }
    func run(_ command: String) async throws -> SSHCommandResult
    func close() async throws
}

extension SSHConnection: SSHSession {
    /// Bridges the protocol's one-argument `run` onto the real method's
    /// defaults.
    func run(_ command: String) async throws -> SSHCommandResult {
        try await run(command, maxResponseSize: 1 << 20, timeoutSeconds: Self.operationTimeoutSeconds)
    }
}

/// Validates the server's host key against a previously-pinned fingerprint
/// (trust-on-first-use, like `~/.ssh/known_hosts`) instead of accepting any
/// key — `SSHHostKeyValidator.acceptAnything()` would make every connection
/// silently vulnerable to a MITM. `nil` `expectedFingerprint` means "no
/// pinned key yet" (first-ever connect to this server): it's accepted and
/// recorded via `observedFingerprint` for the caller to persist.
///
/// `internal` rather than file-private so the host-key tests can drive it
/// directly: this is the check that stands between a normal reconnect and a
/// machine-in-the-middle, and it is not reachable any other way without a
/// live SSH daemon.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private(set) var observedFingerprint: String?

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.readableBytesView
        let digest = SHA256.hash(data: Data(bytes))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        observedFingerprint = fingerprint

        if let expectedFingerprint, expectedFingerprint != fingerprint {
            validationCompletePromise.fail(SSHCommandRunnerError.hostKeyMismatch)
            return
        }
        validationCompletePromise.succeed(())
    }
}

/// One connected SSH session — always the product of a successful TOFU
/// host-key check (`hostKeyFingerprint`). The caller (`RemoteServerRepository`)
/// persists `hostKeyFingerprint` onto the `RemoteServer` row the first time
/// it's seen, so every later connection can be pinned against it.
public final class SSHConnection: @unchecked Sendable {
    private let client: SSHClient
    public let hostKeyFingerprint: String

    /// Upper bound for any single operation on an established session.
    /// Generous enough for the slowest allowlisted action (`nginx -t`, a
    /// service restart) while still bounded — the point is that a wedged
    /// server can't hold a Task forever, not to police slow commands.
    public static let operationTimeoutSeconds = 30

    fileprivate init(client: SSHClient, hostKeyFingerprint: String) {
        self.client = client
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    /// Races `operation` against a sleeper so a post-handshake stall ends in
    /// an error instead of hanging.
    ///
    /// Cancelling the losing child only stops the operation if the underlying
    /// NIO stream honours cancellation, which it does for the async sequences
    /// Citadel builds on. The caller closes the connection on any thrown
    /// error, so the session doesn't leak either way.
    ///
    /// `static` because it touches nothing on the connection, which also
    /// makes the race itself testable without an SSH daemon to connect to.
    static func withDeadline<T: Sendable>(
        _ seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw SSHCommandRunnerError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SSHCommandRunnerError.timedOut(seconds: seconds)
            }
            return first
        }
    }

    /// Runs one command and always returns a result (never throws for a
    /// non-zero exit) — `RemoteCommandExecutor` needs the exit code itself
    /// (e.g. `nginx -t` failing is an expected, displayable outcome, not a
    /// Swift error), and needs stdout/stderr kept apart rather than merged.
    public func run(
        _ command: String,
        maxResponseSize: Int = 1 << 20,
        timeoutSeconds: Int = SSHConnection.operationTimeoutSeconds
    ) async throws -> SSHCommandResult {
        try await Self.withDeadline(timeoutSeconds) { [self] in
            var stdout = ByteBuffer()
            var stderr = ByteBuffer()
            var exitCode = 0

            let stream = try await client.executeCommandStream(command)
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer):
                        if stdout.readableBytes + buffer.readableBytes <= maxResponseSize {
                            var buffer = buffer
                            stdout.writeBuffer(&buffer)
                        }
                    case .stderr(let buffer):
                        if stderr.readableBytes + buffer.readableBytes <= maxResponseSize {
                            var buffer = buffer
                            stderr.writeBuffer(&buffer)
                        }
                    }
                }
            } catch let failure as SSHClient.CommandFailed {
                exitCode = failure.exitCode
            }

            return SSHCommandResult(
                exitCode: exitCode,
                stdout: String(buffer: stdout),
                stderr: String(buffer: stderr)
            )
        }
    }

    /// Reads a file's full contents over SFTP — used for nginx config
    /// (Phase 2). Path allowlisting happens one layer up, in
    /// `RemoteCommandExecutor`; this type has no notion of it.
    public func readFile(_ path: String, timeoutSeconds: Int = SSHConnection.operationTimeoutSeconds) async throws -> String {
        try await Self.withDeadline(timeoutSeconds) { [self] in
            let buffer = try await client.withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: .read) { file in
                    try await file.readAll()
                }
            }
            return String(buffer: buffer)
        }
    }

    /// Overwrites (or creates) a file over SFTP — `.truncate` so shorter
    /// replacement content doesn't leave stale bytes trailing the old file.
    public func writeFile(_ path: String, content: String, timeoutSeconds: Int = SSHConnection.operationTimeoutSeconds) async throws {
        try await Self.withDeadline(timeoutSeconds) { [self] in
            try await client.withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                    try await file.write(ByteBuffer(string: content))
                }
            }
        }
    }

    public func close() async throws {
        try await client.close()
    }
}

/// Connects to a server's SSH daemon and authenticates — the single choke
/// point `RemoteCommandExecutor` goes through for every allowlisted action,
/// per docs/remote-server-management-plan.md's "no free-form shell command"
/// principle (this type itself has no notion of an allowlist; that's the
/// executor's job).
public enum SSHCommandRunner {
    public static func connect(
        host: String,
        port: Int,
        username: String,
        credential: SSHAuthCredential,
        pinnedHostKeyFingerprint: String?,
        connectTimeoutSeconds: Int64 = 10
    ) async throws -> SSHConnection {
        let authMethod = try authenticationMethod(username: username, credential: credential)
        let validator = TOFUHostKeyValidator(expectedFingerprint: pinnedHostKeyFingerprint)

        // No `algorithms:` argument on purpose. NIOSSH's defaults are
        // modern-only — AES256/128-GCM for transport, ECDH over Curve25519 and
        // P256/384/521 for key exchange, ed25519/ecdsa host keys — checked
        // against the vendored source rather than assumed.
        //
        // Citadel's `SSHAlgorithms.all` reads like the safe, thorough choice
        // and is the opposite: it *adds* DiffieHellmanGroup14Sha1 and
        // AES128CTR to that list. Passing it here would weaken every
        // connection, so don't.

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(connectTimeoutSeconds)
            )
        } catch let error as SSHCommandRunnerError {
            // Already one of ours (e.g. `hostKeyMismatch`, thrown by
            // `TOFUHostKeyValidator` through the failed validation promise)
            // — has its own specific, already-clear message.
            throw error
        } catch {
            throw SSHCommandRunnerError.connectionFailed(String(describing: error))
        }

        // The validator always records a fingerprint before succeeding
        // (see `validateHostKey` above) — `connect` only reaches this line
        // once that validation has already passed.
        let fingerprint = validator.observedFingerprint ?? ""
        return SSHConnection(client: client, hostKeyFingerprint: fingerprint)
    }

    static func authenticationMethod(username: String, credential: SSHAuthCredential) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let pem, let passphrase):
            let decryptionKey = passphrase.map { Data($0.utf8) }
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: pem)
            switch keyType {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            default:
                throw SSHCommandRunnerError.unsupportedPrivateKeyFormat(keyType.description)
            }
        }
    }
}
