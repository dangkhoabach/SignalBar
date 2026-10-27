import Foundation
import GRDB

/// The real `RemoteStatsProviding`: reads the opted-in servers and asks each
/// one for its stats over a single SSH session (`RemoteCommandExecutor.stats`).
public struct SSHRemoteStatsProvider: RemoteStatsProviding {
    private let repo: RemoteServerRepository
    private let executor: RemoteCommandExecutor

    public init(dbQueue: DatabaseQueue, keychain: KeychainStoring = KeychainStore()) {
        self.repo = RemoteServerRepository(dbQueue: dbQueue, keychain: keychain)
        self.executor = RemoteCommandExecutor(repo: repo)
    }

    public func monitoredServers() throws -> [RemoteServer] {
        try repo.list().filter(\.monitoringEnabled)
    }

    public func stats(for server: RemoteServer) async throws -> RemoteServerStats {
        try await executor.stats(on: server)
    }
}
