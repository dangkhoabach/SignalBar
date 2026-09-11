import Foundation
import Security

/// A credential lives as its own Keychain item (never one blob per server) so
/// a private key and its passphrase can be looked up — and, later, access-
/// controlled — independently. `password` is the fallback auth method's
/// secret; it gets the exact same protection as a private key, no exception.
public enum KeychainSecretKind: String, Sendable {
    case privateKey, passphrase, password
}

public enum KeychainStoreError: Error, Sendable, Equatable {
    case notFound
    case unhandledStatus(OSStatus)
}

extension KeychainStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Credential not found in Keychain."
        case .unhandledStatus(let status):
            "Keychain error (status \(status))."
        }
    }
}

/// Lets `RemoteServerRepository` be tested against an in-memory fake
/// (`RemoteServerRepositoryTests`) instead of the real Keychain — real
/// Keychain access needs a properly signed app process (see this type's doc
/// comment) and would otherwise fail outright under `swift test`.
public protocol KeychainStoring: Sendable {
    func set(ref: String, kind: KeychainSecretKind, data: Data) throws
    func delete(ref: String, kind: KeychainSecretKind) throws
    func deleteAll(ref: String) throws
    func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data
    func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data
}

/// Stores SSH credentials for remote servers per
/// docs/remote-server-management-plan.md §1a.
///
/// The original design additionally wrapped every item in a
/// `SecAccessControl([.userPresence])`, requiring Touch ID/the device
/// password on every single read. **That had to be dropped**: any
/// `SecAccessControl`-protected item — even with zero flags — fails
/// `SecItemAdd`/`SecItemCopyMatching` with `errSecMissingEntitlement`
/// (-34018) unless the app is signed with a real Development/Developer ID
/// certificate carrying a matching `keychain-access-groups` entitlement.
/// This app's local debug builds are ad-hoc signed (no Team ID), so that
/// path is unavailable without the user first configuring a signing team in
/// Xcode — confirmed empirically (see the diagnostic script referenced in
/// the plan's changelog) before making this call, not assumed.
///
/// What's kept:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: never leaves this Mac
///   via iCloud Keychain sync, and unreadable while the machine is locked —
///   this alone is what the large majority of macOS apps storing credentials
///   rely on, entitlement-free.
/// - No `kSecAttrAccessGroup`: only this app's own process reads its items.
///
/// What's lost: there's no per-read Touch ID/passcode re-prompt. If this app
/// is ever signed with a real Developer ID + `keychain-access-groups`
/// entitlement (already true of the notarized release build, per
/// docs/swift-native-port-plan.md's D3), `SecAccessControl` can be
/// reinstated — `readForStatusCheck`/`readForMutatingAction` are kept as two
/// distinct methods (rather than collapsed into one) specifically so that
/// reinstatement only touches this file, not any call site.
public struct KeychainStore: KeychainStoring, Sendable {
    private static let service = "com.dangkhoabach.dkb-monitor.remote-ssh"

    public init() {}

    public func set(ref: String, kind: KeychainSecretKind, data: Data) throws {
        let account = Self.account(ref: ref, kind: kind)

        // Delete-then-add (rather than SecItemUpdate) — simplest way to
        // guarantee a stale item with different attributes never lingers.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStoreError.unhandledStatus(status) }
    }

    public func delete(ref: String, kind: KeychainSecretKind) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(ref: ref, kind: kind),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    /// Removes every secret kind stored under `ref` — used when a
    /// `RemoteServer` row is deleted, so a stray Keychain item never outlives
    /// the server it belonged to.
    public func deleteAll(ref: String) throws {
        for kind: KeychainSecretKind in [.privateKey, .passphrase, .password] {
            try delete(ref: ref, kind: kind)
        }
    }

    /// Identical to `readForMutatingAction` today (see this type's doc
    /// comment) — kept as its own method so a future `SecAccessControl`
    /// reinstatement only has to change these two bodies.
    public func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref: ref, kind: kind)
    }

    public func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref: ref, kind: kind)
    }

    private func read(ref: String, kind: KeychainSecretKind) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(ref: ref, kind: kind),
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainStoreError.notFound : KeychainStoreError.unhandledStatus(status)
        }
        guard let data = result as? Data else { throw KeychainStoreError.notFound }
        return data
    }

    private static func account(ref: String, kind: KeychainSecretKind) -> String {
        "\(ref).\(kind.rawValue)"
    }
}
