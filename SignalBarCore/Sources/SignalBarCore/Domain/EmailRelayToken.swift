import Foundation

/// Where this install's relay bearer token lives. Behind a protocol so the
/// relay's own tests can run without a signed process — the real Keychain is
/// unavailable under `swift test` for the same reason documented on
/// `KeychainStore`.
public protocol EmailRelayTokenStoring: Sendable {
    func token() -> String?
    func save(_ token: String) throws
    func clear() throws
}

/// The token is a bearer credential with no expiry: whoever holds it can have
/// mail delivered to the address it was issued for, forever. That puts it in
/// the same class as the SSH secrets next door, so it gets the same storage
/// rather than a row in SQLite.
public struct KeychainEmailRelayTokenStore: EmailRelayTokenStoring {
    /// One token per install, so unlike the SSH credentials there is nothing
    /// to key it by.
    private static let ref = "install"

    private let keychain: any KeychainStoring

    public init(keychain: any KeychainStoring = KeychainStore(service: KeychainStore.emailRelayService)) {
        self.keychain = keychain
    }

    public func token() -> String? {
        guard let data = try? keychain.readForStatusCheck(ref: Self.ref, kind: .emailRelayToken) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        try keychain.set(ref: Self.ref, kind: .emailRelayToken, data: Data(token.utf8))
    }

    public func clear() throws {
        try keychain.delete(ref: Self.ref, kind: .emailRelayToken)
    }
}
