import SignalBarCore
import Foundation
import Observation

/// Drives `RemoteServerDetailView`: manage the systemd service
/// allowlist, check status, and run Start/Stop/Restart through
/// `RemoteCommandExecutor` (never a raw command).
@MainActor
@Observable
final class RemoteServerDetailViewModel {
    private let repo: RemoteServerRepository?
    private let executor: RemoteCommandExecutor?

    var server: RemoteServer?
    var allowlistedServices: [RemoteAllowlistEntry] = []
    /// Service name -> last-known `systemctl is-active` output.
    var serviceStatuses: [String: String] = [:]
    var commandLog: [RemoteCommandLogEntry] = []
    var errorMessage: String?
    var newServiceName = ""

    // MARK: - Nginx

    var allowlistedConfigPaths: [RemoteAllowlistEntry] = []
    var newConfigPath = ""
    /// The path currently open in the editor, and its (possibly edited,
    /// unsaved) content.
    var openConfigPath: String?
    var configEditorText = ""
    var isLoadingConfig = false
    var nginxTestOutput: String?
    /// `nil` = not tested since the last save/path switch — Reload stays
    /// disabled until this is `true`: a reload only follows a passing test of
    /// the latest config.
    var nginxTestPassed: Bool?

    // MARK: - Logs

    var allowlistedLogPaths: [RemoteAllowlistEntry] = []
    var newLogPath = ""
    var selectedLogPath: String?
    var logLineCount = 100
    var logOutput = ""

    // MARK: - Stats

    var diskUsage: RemoteDiskUsage?
    var memoryUsage: RemoteMemoryUsage?
    var uptime: RemoteUptime?
    var cpuUsage: RemoteCPUUsage?
    var osInfo: RemoteOSInfo?
    var statsErrorMessage: String?

    /// Keys currently mid-flight — `"status:<name>"` or a mutating action's
    /// `RemoteAction.logName` — so the right row/button alone shows a
    /// spinner instead of blocking the whole screen.
    var runningKeys: Set<String> = []
    /// Set by a Start/Stop/Restart button; cleared once the
    /// confirmationDialog is answered either way.
    var pendingAction: RemoteAction?

    init(repo: RemoteServerRepository?) {
        self.repo = repo
        self.executor = repo.map { RemoteCommandExecutor(repo: $0) }
    }

    func load(serverId: Int64) {
        guard let repo else { return }
        server = try? repo.get(id: serverId)
        let allowlist = (try? repo.allowlist(serverId: serverId)) ?? []
        allowlistedServices = allowlist.filter { $0.kind == .service }
        allowlistedConfigPaths = allowlist.filter { $0.kind == .nginxConfigPath }
        allowlistedLogPaths = allowlist.filter { $0.kind == .logPath }
        commandLog = (try? repo.recentLog(serverId: serverId)) ?? []
    }

    // MARK: - Allowlist

    func addServiceToAllowlist() {
        let trimmed = newServiceName.trimmingCharacters(in: .whitespaces)
        guard let repo, let serverId = server?.id, !trimmed.isEmpty else { return }
        guard RemoteCommandExecutor.isValidServiceName(trimmed) else {
            errorMessage = "\"\(trimmed)\" isn't a valid systemd unit name."
            return
        }
        guard !allowlistedServices.contains(where: { $0.value == trimmed }) else {
            newServiceName = ""
            return
        }
        do {
            try repo.addAllowlistEntry(serverId: serverId, kind: .service, value: trimmed)
            newServiceName = ""
            load(serverId: serverId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeServiceFromAllowlist(_ entry: RemoteAllowlistEntry) {
        guard let repo, let serverId = server?.id else { return }
        try? repo.removeAllowlistEntry(id: entry.id!)
        serviceStatuses.removeValue(forKey: entry.value)
        load(serverId: serverId)
    }

    // MARK: - Actions

    func isRunning(_ key: String) -> Bool { runningKeys.contains(key) }

    func refreshStatus(_ serviceName: String) {
        guard let server, let executor else { return }
        run(key: "status:\(serviceName)", action: .serviceStatus(name: serviceName), server: server, executor: executor) { result in
            self.serviceStatuses[serviceName] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Called after the confirm dialog is accepted.
    func confirmPendingAction() {
        guard let action = pendingAction, let server, let executor else { return }
        pendingAction = nil
        run(key: action.logName, action: action, server: server, executor: executor) { [weak self] _ in
            switch action {
            case .serviceStart(let name), .serviceStop(let name), .serviceRestart(let name):
                self?.refreshStatus(name)
            case .serviceStatus, .nginxTest, .nginxReload, .tailLog, .diskUsage, .memoryUsage, .uptime, .cpuUsage, .osInfo:
                break
            }
        }
    }

    private func run(
        key: String, action: RemoteAction, server: RemoteServer, executor: RemoteCommandExecutor,
        onSuccess: @escaping (SSHCommandResult) -> Void
    ) {
        runningKeys.insert(key)
        Task {
            defer { runningKeys.remove(key) }
            do {
                let result = try await executor.execute(action, on: server)
                if result.succeeded {
                    onSuccess(result)
                } else {
                    errorMessage = "Command failed (exit \(result.exitCode)): \(result.stderr)"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            if let id = server.id { load(serverId: id) }
        }
    }

    // MARK: - Nginx allowlist

    func addConfigPathToAllowlist() {
        let trimmed = newConfigPath.trimmingCharacters(in: .whitespaces)
        guard let repo, let serverId = server?.id, !trimmed.isEmpty else { return }
        guard RemoteCommandExecutor.isValidConfigPath(trimmed) else {
            errorMessage = "\"\(trimmed)\" must be an absolute path under /etc/nginx/."
            return
        }
        guard !allowlistedConfigPaths.contains(where: { $0.value == trimmed }) else {
            newConfigPath = ""
            return
        }
        do {
            try repo.addAllowlistEntry(serverId: serverId, kind: .nginxConfigPath, value: trimmed)
            newConfigPath = ""
            load(serverId: serverId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeConfigPathFromAllowlist(_ entry: RemoteAllowlistEntry) {
        guard let repo, let serverId = server?.id else { return }
        try? repo.removeAllowlistEntry(id: entry.id!)
        if openConfigPath == entry.value { closeConfig() }
        load(serverId: serverId)
    }

    // MARK: - Nginx config editor

    func openConfig(_ path: String) {
        guard let server, let executor else { return }
        openConfigPath = path
        configEditorText = ""
        nginxTestOutput = nil
        nginxTestPassed = nil
        isLoadingConfig = true
        Task {
            // Tapping a second path before the first finished loading must
            // not let the first (now-stale) read land after the second's —
            // without this guard, a slow first fetch could overwrite the
            // editor with the *wrong file's* content (and briefly flip
            // `isLoadingConfig` back to false mid-way through the second
            // fetch, which would have defeated Save's disabled-while-loading
            // guard above).
            do {
                let content = try await executor.readConfig(path: path, on: server)
                guard openConfigPath == path else { return }
                configEditorText = content
                isLoadingConfig = false
            } catch {
                guard openConfigPath == path else { return }
                errorMessage = error.localizedDescription
                openConfigPath = nil
                isLoadingConfig = false
            }
        }
    }

    func closeConfig() {
        openConfigPath = nil
        configEditorText = ""
        nginxTestOutput = nil
        nginxTestPassed = nil
    }

    func saveConfig() {
        guard let server, let executor, let path = openConfigPath else { return }
        let key = "writeFile(\(path))"
        let content = configEditorText
        runningKeys.insert(key)
        // A save invalidates any earlier "Test passed" result — the file on
        // disk changed, so Reload must stay gated behind a fresh Test.
        nginxTestOutput = nil
        nginxTestPassed = nil
        Task {
            defer { runningKeys.remove(key) }
            do {
                try await executor.writeConfig(path: path, content: content, on: server)
            } catch {
                errorMessage = error.localizedDescription
            }
            if let id = server.id { load(serverId: id) }
        }
    }

    /// Doesn't go through the generic `run` helper — that only surfaces a
    /// non-zero exit as a generic `errorMessage`, but `nginx -t`'s actually
    /// useful message (which line is broken) is on stderr of exactly that
    /// failing run, and belongs in `nginxTestOutput`, not a transient alert.
    func runNginxTest() {
        guard let server, let executor else { return }
        let key = RemoteAction.nginxTest.logName
        runningKeys.insert(key)
        Task {
            defer { runningKeys.remove(key) }
            do {
                let result = try await executor.execute(.nginxTest, on: server)
                nginxTestOutput = result.stderr.isEmpty ? result.stdout : result.stderr
                nginxTestPassed = result.succeeded
            } catch {
                errorMessage = error.localizedDescription
            }
            if let id = server.id { load(serverId: id) }
        }
    }

    func requestReload() {
        pendingAction = .nginxReload
    }

    // MARK: - Log allowlist

    func addLogPathToAllowlist() {
        let trimmed = newLogPath.trimmingCharacters(in: .whitespaces)
        guard let repo, let serverId = server?.id, !trimmed.isEmpty else { return }
        guard RemoteCommandExecutor.isValidLogPath(trimmed) else {
            errorMessage = "\"\(trimmed)\" must be an absolute path."
            return
        }
        guard !allowlistedLogPaths.contains(where: { $0.value == trimmed }) else {
            newLogPath = ""
            return
        }
        do {
            try repo.addAllowlistEntry(serverId: serverId, kind: .logPath, value: trimmed)
            newLogPath = ""
            load(serverId: serverId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeLogPathFromAllowlist(_ entry: RemoteAllowlistEntry) {
        guard let repo, let serverId = server?.id else { return }
        try? repo.removeAllowlistEntry(id: entry.id!)
        if selectedLogPath == entry.value {
            selectedLogPath = nil
            logOutput = ""
        }
        load(serverId: serverId)
    }

    // MARK: - Log tailing

    func selectLogPath(_ path: String) {
        selectedLogPath = path
        logOutput = ""
        refreshLog()
    }

    func refreshLog() {
        guard let server, let executor, let path = selectedLogPath else { return }
        let action = RemoteAction.tailLog(path: path, lines: logLineCount)
        run(key: action.logName, action: action, server: server, executor: executor) { [weak self] result in
            // Selecting a different log path while this fetch was still in
            // flight must not let its (now-stale) result land under the
            // newly-selected path's label.
            guard self?.selectedLogPath == path else { return }
            self?.logOutput = result.stdout
        }
    }

    // MARK: - Stats

    static let statsKey = "stats"

    /// Manual refresh only (no auto-poll, by design), and all five
    /// readings over a single SSH session.
    ///
    /// This used to open one connection per stat. Each one costs a full
    /// TCP + key exchange + auth handshake, so a single click on Refresh
    /// paid that five times — the bulk of the wait on a slow link or an RSA
    /// key, before any command had run. It also meant an earlier grouping
    /// dance: two `do` blocks, arranged so a failure in the commands most
    /// likely to be missing (`top`, `/etc/os-release`) wouldn't discard the
    /// three that had already succeeded. `stats(on:)` reports each reading
    /// independently, so no arrangement is needed to keep partial results.
    func refreshStats() {
        guard let server, let executor else { return }
        runningKeys.insert(Self.statsKey)
        statsErrorMessage = nil
        Task {
            defer { runningKeys.remove(Self.statsKey) }
            do {
                let stats = try await executor.stats(on: server)
                if let disk = stats.disk { diskUsage = disk }
                if let memory = stats.memory { memoryUsage = memory }
                if let up = stats.uptime { uptime = up }
                if let cpu = stats.cpu { cpuUsage = cpu }
                if let os = stats.os { osInfo = os }
                statsErrorMessage = stats.failures.isEmpty
                    ? nil : stats.failures.joined(separator: "\n")
            } catch {
                // Only the session itself failing lands here, and then
                // nothing ran at all.
                statsErrorMessage = error.localizedDescription
            }
            if let id = server.id { load(serverId: id) }
        }
    }
}
