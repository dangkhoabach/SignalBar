import Foundation
import LocalAuthentication
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
/// Keychain access needs a signed, entitled app process and would otherwise
/// hang `swift test` waiting on a Touch ID/passcode prompt that can't appear.
public protocol KeychainStoring: Sendable {
    func set(ref: String, kind: KeychainSecretKind, data: Data) throws
    func delete(ref: String, kind: KeychainSecretKind) throws
    func deleteAll(ref: String) throws
    func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data
    func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data
}

/// Stores SSH credentials for remote servers per
/// docs/remote-server-management-plan.md §1a — the strictest configuration
/// the Keychain offers:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: never leaves this Mac via
///   iCloud Keychain sync, unreadable while the machine is locked.
/// - `SecAccessControl([.userPresence])`: every read requires Touch ID or the
///   device password — there is no "just read it" path.
/// - No `kSecAttrAccessGroup`: only this app's own process can read its items.
///
/// `readForStatusCheck` and `readForMutatingAction` both authenticate on
/// every call; they differ only in `LAContext.touchIDAuthenticationAllowableReuseDuration`,
/// which lets a burst of read-only status checks (service status, log tail)
/// ride on a recent authentication instead of re-prompting every few seconds,
/// while a mutating action (restart/reload/write) always uses a fresh context
/// so it never silently rides on an old approval from minutes ago for an
/// unrelated read.
public struct KeychainStore: KeychainStoring, Sendable {
    private static let service = "com.dangkhoabach.dkb-monitor.remote-ssh"
    private static let statusCheckReuseWindow: TimeInterval = 300

    public init() {}

    public func set(ref: String, kind: KeychainSecretKind, data: Data) throws {
        let account = Self.account(ref: ref, kind: kind)
        let accessControl = try Self.makeAccessControl()

        // Delete-then-add (rather than SecItemUpdate) because the access
        // control attribute can't be modified in place on an existing item.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessControl as String] = accessControl

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

    public func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = Self.statusCheckReuseWindow
        return try read(ref: ref, kind: kind, context: context)
    }

    public func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref: ref, kind: kind, context: LAContext())
    }

    private func read(ref: String, kind: KeychainSecretKind, context: LAContext) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(ref: ref, kind: kind),
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
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

    private static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        return control
    }
}
