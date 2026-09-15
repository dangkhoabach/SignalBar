import Foundation

/// What one server made of a bulk action.
public struct RemoteBulkOutcome: Sendable, Identifiable {
    public let serverId: Int64
    public let serverName: String
    public let result: Result<SSHCommandResult, any Error>

    public var id: Int64 { serverId }

    public var succeeded: Bool {
        switch result {
        case .success(let command): command.succeeded
        case .failure: false
        }
    }

    /// One line fit for a results table — the command's own stderr where
    /// there is one, since "exit 1" alone never explains anything.
    public var summary: String {
        switch result {
        case .success(let command) where command.succeeded:
            command.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case .success(let command):
            "Exit \(command.exitCode): \(command.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .failure(let error):
            error.localizedDescription
        }
    }

    public init(serverId: Int64, serverName: String, result: Result<SSHCommandResult, any Error>) {
        self.serverId = serverId
        self.serverName = serverName
        self.result = result
    }
}

/// Runs one allowlisted action across several servers at once.
///
/// This adds no new capability: every action still goes through
/// `RemoteCommandExecutor`, so each server's own allowlist decides whether
/// the action is permitted there. A server that has not allowlisted the
/// action fails on its own row and the rest of the batch continues — the
/// alternative, aborting the whole run, would make one mis-configured server
/// able to block work on every other.
public struct RemoteBulkExecutor: Sendable {
    /// Servers are independent machines, so they run concurrently — that is
    /// the point of the feature. Capped anyway: each one costs a full SSH
    /// handshake, and opening several dozen at once is a burst this Mac's
    /// network gains nothing from.
    static let maxConcurrent = 8

    private let executor: RemoteCommandExecutor

    public init(executor: RemoteCommandExecutor) {
        self.executor = executor
    }

    /// Never throws: a bulk run's whole purpose is reporting per server, and
    /// a thrown error would discard the servers that did succeed.
    public func run(_ action: RemoteAction, on servers: [RemoteServer]) async -> [RemoteBulkOutcome] {
        let targets = servers.filter { $0.id != nil }
        guard !targets.isEmpty else { return [] }

        let outcomes = await withTaskGroup(of: RemoteBulkOutcome.self) { group in
            var started = 0
            var collected: [RemoteBulkOutcome] = []

            func addTask(_ server: RemoteServer) {
                group.addTask {
                    do {
                        let result = try await executor.execute(action, on: server)
                        return RemoteBulkOutcome(serverId: server.id!, serverName: server.name, result: .success(result))
                    } catch {
                        return RemoteBulkOutcome(serverId: server.id!, serverName: server.name, result: .failure(error))
                    }
                }
            }

            while started < min(Self.maxConcurrent, targets.count) {
                addTask(targets[started])
                started += 1
            }
            while let finished = await group.next() {
                collected.append(finished)
                if started < targets.count {
                    addTask(targets[started])
                    started += 1
                }
            }
            return collected
        }

        // A task group finishes in whatever order the network allowed, which
        // would shuffle the results table on every run. Put them back in the
        // order the user selected them.
        let position = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element.id!, $0.offset) })
        return outcomes.sorted { position[$0.serverId, default: 0] < position[$1.serverId, default: 0] }
    }
}
