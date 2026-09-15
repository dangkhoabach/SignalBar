import DKBMonitorCore
import Foundation
import Observation

/// Drives the "run one action across several servers" sheet.
///
/// The sheet exists rather than a multi-select mode on the list because a
/// bulk run needs three things chosen together — which action, which service,
/// which servers — and because everything about it is new UI that the list
/// itself then does not have to grow.
@MainActor
@Observable
final class RemoteBulkActionViewModel {
    /// The subset of `RemoteAction` worth fanning out. Deliberately not the
    /// whole enum: `tailLog` returns pages of text that no shared results
    /// table could show, and the stats readings already have their own
    /// per-server pane.
    enum Kind: String, CaseIterable, Identifiable {
        case status, restart, start, stop, nginxTest, nginxReload, uptime, diskUsage

        var id: String { rawValue }

        var label: String {
            switch self {
            case .status: "Service status"
            case .restart: "Restart service"
            case .start: "Start service"
            case .stop: "Stop service"
            case .nginxTest: "Test nginx config"
            case .nginxReload: "Reload nginx"
            case .uptime: "Uptime"
            case .diskUsage: "Disk usage"
            }
        }

        var needsServiceName: Bool {
            switch self {
            case .status, .restart, .start, .stop: true
            case .nginxTest, .nginxReload, .uptime, .diskUsage: false
            }
        }

        func action(service: String) -> RemoteAction {
            switch self {
            case .status: .serviceStatus(name: service)
            case .restart: .serviceRestart(name: service)
            case .start: .serviceStart(name: service)
            case .stop: .serviceStop(name: service)
            case .nginxTest: .nginxTest
            case .nginxReload: .nginxReload
            case .uptime: .uptime
            case .diskUsage: .diskUsage
            }
        }
    }

    private let repo: RemoteServerRepository?
    private let bulk: RemoteBulkExecutor?

    var servers: [RemoteServer] = []
    var selectedIds: Set<Int64> = []
    var kind: Kind = .status
    var serviceName = ""
    /// Every service name allowlisted on any of these servers — offering a
    /// list rather than a free text field, because a typo here fails on every
    /// selected server at once and only says "not allowlisted".
    var knownServiceNames: [String] = []

    var isRunning = false
    var outcomes: [RemoteBulkOutcome] = []
    var isPresentingConfirm = false

    init(repo: RemoteServerRepository?) {
        self.repo = repo
        self.bulk = repo.map { RemoteBulkExecutor(executor: RemoteCommandExecutor(repo: $0)) }
    }

    var action: RemoteAction {
        kind.action(service: serviceName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var canRun: Bool {
        guard !isRunning, !selectedIds.isEmpty else { return false }
        return !kind.needsServiceName || !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedServers: [RemoteServer] {
        servers.filter { $0.id.map { selectedIds.contains($0) } ?? false }
    }

    func load(servers: [RemoteServer]) {
        self.servers = servers
        outcomes = []
        selectedIds = []

        guard let repo else { return }
        let names = servers
            .compactMap(\.id)
            .flatMap { (try? repo.allowlist(serverId: $0)) ?? [] }
            .filter { $0.kind == .service }
            .map(\.value)
        knownServiceNames = Array(Set(names)).sorted()
        serviceName = knownServiceNames.first ?? ""
    }

    /// Mutating actions ask first — the same rule the single-server pane
    /// follows, and more so here, where one confirm covers several machines.
    func runRequested() {
        if action.isMutating {
            isPresentingConfirm = true
        } else {
            Task { await run() }
        }
    }

    func run() async {
        guard let bulk, canRun else { return }
        let targets = selectedServers
        isRunning = true
        outcomes = []
        outcomes = await bulk.run(action, on: targets)
        isRunning = false
    }

    func toggle(_ server: RemoteServer) {
        guard let id = server.id else { return }
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    func selectAll() {
        selectedIds = Set(servers.compactMap(\.id))
    }

    func clearSelection() {
        selectedIds = []
    }
}
