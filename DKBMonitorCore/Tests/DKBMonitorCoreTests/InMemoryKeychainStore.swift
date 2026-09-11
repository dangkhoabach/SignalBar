import Foundation
@testable import DKBMonitorCore

/// Fakes `KeychainStoring` for tests — plain in-memory dictionary, no real
/// Keychain/Touch ID involved (see the protocol's doc comment for why).
final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    func set(ref: String, kind: KeychainSecretKind, data: Data) throws {
        storage[key(ref, kind)] = data
    }

    func delete(ref: String, kind: KeychainSecretKind) throws {
        storage.removeValue(forKey: key(ref, kind))
    }

    func deleteAll(ref: String) throws {
        for kind: KeychainSecretKind in [.privateKey, .passphrase, .password] {
            storage.removeValue(forKey: key(ref, kind))
        }
    }

    func readForStatusCheck(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref, kind)
    }

    func readForMutatingAction(ref: String, kind: KeychainSecretKind) throws -> Data {
        try read(ref, kind)
    }

    private func read(_ ref: String, _ kind: KeychainSecretKind) throws -> Data {
        guard let data = storage[key(ref, kind)] else { throw KeychainStoreError.notFound }
        return data
    }

    private func key(_ ref: String, _ kind: KeychainSecretKind) -> String { "\(ref).\(kind.rawValue)" }
}
