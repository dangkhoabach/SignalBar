import Crypto
import Foundation
import NIO
import NIOSSH
import Testing
@testable import SignalBarCore

/// Covers the two parts of the SSH layer that don't need a server to be
/// meaningful: the host-key decision, and the deadline that stops a wedged
/// session holding a Task open forever.
///
/// Everything past the handshake (`run`, `readFile`, `writeFile`) goes
/// through a live `SSHClient` and stays out of scope here.
@Suite struct SSHCommandRunnerTests {
    private func publicKey() -> NIOSSHPublicKey {
        NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    }

    private func validate(
        _ validator: TOFUHostKeyValidator,
        key: NIOSSHPublicKey
    ) -> Result<Void, Error> {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        do {
            try promise.futureResult.wait()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func isMismatch(_ result: Result<Void, Error>) -> Bool {
        if case .failure(let error) = result, case SSHCommandRunnerError.hostKeyMismatch = error { return true }
        return false
    }

    // MARK: - Host key (TOFU)

    /// First contact: nothing is pinned yet, so the key is accepted and
    /// recorded — that recorded value is what every later connection is
    /// checked against.
    @Test func firstContactAcceptsTheKeyAndRecordsItsFingerprint() throws {
        let validator = TOFUHostKeyValidator(expectedFingerprint: nil)
        let result = validate(validator, key: publicKey())

        #expect(try result.get() == ())
        #expect(validator.observedFingerprint?.count == 64)
    }

    @Test func aKeyMatchingThePinIsAccepted() throws {
        let key = publicKey()
        let first = TOFUHostKeyValidator(expectedFingerprint: nil)
        _ = validate(first, key: key)
        let pinned = try #require(first.observedFingerprint)

        let second = TOFUHostKeyValidator(expectedFingerprint: pinned)
        #expect(try validate(second, key: key).get() == ())
        #expect(second.observedFingerprint == pinned)
    }

    /// The whole point of pinning: a server presenting a different key than
    /// the one seen before is refused rather than silently trusted, because
    /// that is what a machine-in-the-middle looks like.
    @Test func aDifferentKeyThanThePinIsRefused() throws {
        let first = TOFUHostKeyValidator(expectedFingerprint: nil)
        _ = validate(first, key: publicKey())
        let pinned = try #require(first.observedFingerprint)

        let second = TOFUHostKeyValidator(expectedFingerprint: pinned)
        #expect(isMismatch(validate(second, key: publicKey())))
    }

    @Test func theSameKeyAlwaysHashesToTheSameFingerprint() throws {
        let key = publicKey()
        let a = TOFUHostKeyValidator(expectedFingerprint: nil)
        let b = TOFUHostKeyValidator(expectedFingerprint: nil)
        _ = validate(a, key: key)
        _ = validate(b, key: key)

        #expect(a.observedFingerprint == b.observedFingerprint)
        #expect(a.observedFingerprint?.allSatisfy { $0.isHexDigit } == true)
    }

    /// Two different keys must not collide into one fingerprint, or pinning
    /// would accept a key it never saw.
    @Test func differentKeysHashToDifferentFingerprints() {
        let a = TOFUHostKeyValidator(expectedFingerprint: nil)
        let b = TOFUHostKeyValidator(expectedFingerprint: nil)
        _ = validate(a, key: publicKey())
        _ = validate(b, key: publicKey())

        #expect(a.observedFingerprint != b.observedFingerprint)
    }

    // MARK: - Operation deadline

    @Test func anOperationThatFinishesInTimeReturnsItsValue() async throws {
        let value = try await SSHConnection.withDeadline(30) { "done" }
        #expect(value == "done")
    }

    /// A server that accepts the connection and then goes quiet used to hold
    /// the calling Task open indefinitely.
    @Test func anOperationThatOutlastsTheDeadlineThrowsTimedOut() async {
        await #expect(throws: SSHCommandRunnerError.timedOut(seconds: 1)) {
            try await SSHConnection.withDeadline(1) {
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
        }
    }

    /// The deadline must not swallow or reshape a real failure into a
    /// timeout — the error the caller sees has to be the one that happened.
    @Test func anOperationThatFailsPropagatesItsOwnError() async {
        await #expect(throws: SSHCommandRunnerError.hostKeyMismatch) {
            try await SSHConnection.withDeadline(30) {
                throw SSHCommandRunnerError.hostKeyMismatch
            }
        }
    }

    // MARK: - Credentials

    @Test func aPasswordCredentialNeedsNoParsing() throws {
        _ = try SSHCommandRunner.authenticationMethod(username: "deploy", credential: .password("s3cr3t"))
    }

    @Test func textThatIsNotAPrivateKeyIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try SSHCommandRunner.authenticationMethod(
                username: "deploy",
                credential: .privateKey(pem: "definitely not a key", passphrase: nil)
            )
        }
    }
}
