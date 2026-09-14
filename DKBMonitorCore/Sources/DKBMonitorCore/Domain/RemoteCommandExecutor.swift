import Foundation

public enum RemoteCommandExecutorError: Error, Sendable, Equatable {
    case serverNotSaved
    case notAllowlisted(String)
    case invalidAllowlistValue(String)
    case parseFailure(String)
}

extension RemoteCommandExecutorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serverNotSaved:
            "This server hasn't been saved yet."
        case .notAllowlisted(let value):
            "\"\(value)\" isn't in this server's allowlist."
        case .invalidAllowlistValue(let value):
            "\"\(value)\" isn't a valid value for this action."
        case .parseFailure(let what):
            "Couldn't understand the server's response (\(what))."
        }
    }
}

/// The single place a `RemoteAction` (or a config file read/write, which
/// isn't itself a `RemoteAction` — see below) turns into an actual SSH/SFTP
/// call — verifies the target is allowlisted for this server, connects,
/// runs it, and always writes the attempt to `remote_command_log`, per
/// docs/remote-server-management-plan.md's security principles. No caller
/// outside this type ever builds a shell command string or touches
/// `SSHCommandRunner` directly.
public struct RemoteCommandExecutor: Sendable {
    private let repo: RemoteServerRepository

    public init(repo: RemoteServerRepository) {
        self.repo = repo
    }

    /// Restricts service unit names to what systemd itself accepts, and
    /// nothing else — this is what keeps `shellCommand(for:)` safe to
    /// interpolate directly instead of needing shell-argument quoting.
    /// Enforced both when adding an allowlist entry (UI) and again here
    /// before every execution, so a row already saved before this
    /// validation existed still can't be abused.
    public static func isValidServiceName(_ name: String) -> Bool {
        !name.isEmpty
            && hasNoControlCharacters(name)
            && name.range(of: #"^[A-Za-z0-9@._-]+$"#, options: .regularExpression) != nil
    }

    /// Rejects newlines, NULs and other control characters outright.
    ///
    /// The patterns below don't currently need this: `range(of:options:
    /// .regularExpression)` rejects `"nginx\n"` already, verified rather than
    /// assumed. `NSRegularExpression` on the same pattern does *not* — ICU
    /// anchors `$` before a single trailing newline — so the safety of these
    /// validators rests on which regex API they happen to call. Checking the
    /// characters directly states the requirement instead of inheriting it.
    private static func hasNoControlCharacters(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Restricts nginx config paths to `/etc/nginx/...` with no `..`
    /// traversal — defense in depth on top of the allowlist itself (which
    /// the server's own owner controls), so a typo'd or later-introduced
    /// allowlist entry can never point `readConfig`/`writeConfig` at an
    /// arbitrary file like `/etc/passwd`.
    public static func isValidConfigPath(_ path: String) -> Bool {
        path.hasPrefix("/etc/nginx/")
            && !path.contains("..")
            && hasNoControlCharacters(path)
            && path.range(of: #"^[A-Za-z0-9/_.\-]+$"#, options: .regularExpression) != nil
    }

    /// Log paths aren't restricted to one directory the way nginx config is
    /// (app logs, Docker container logs, etc. live all over) — still
    /// requires an absolute path with no `..` traversal and a safe
    /// character set, since it's interpolated directly into `tail -n N
    /// <path>` (see `shellCommand(for:)`).
    public static func isValidLogPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.contains("..")
            && hasNoControlCharacters(path)
            && path.range(of: #"^[A-Za-z0-9/_.\-]+$"#, options: .regularExpression) != nil
    }

    /// `tail -n <lines>` — clamped so a mistyped huge value can't pull back
    /// an unbounded response.
    public static func clampedTailLines(_ lines: Int) -> Int {
        min(max(lines, 1), 2000)
    }

    // MARK: - Systemd services / nginx test+reload (shell exec)

    @discardableResult
    public func execute(_ action: RemoteAction, on server: RemoteServer) async throws -> SSHCommandResult {
        let serverId = try requireSavedId(server)
        try requireAuthorized(action, serverId: serverId)

        // `connection` starts nil and is assigned only once `connect`
        // actually succeeds — the catch block below only needs to close it
        // when it exists, but logs the attempt either way, so a connection
        // failure (bad host, timeout, rejected auth) shows up in the audit
        // trail exactly like a failed command does, instead of vanishing
        // silently before anything was ever "executed".
        var connection: SSHConnection?
        do {
            let established = try await connect(server: server, forMutatingAction: action.isMutating)
            connection = established
            // Pinned the moment the handshake succeeds, not after the command
            // returns: a first-ever connect whose command then failed (network
            // blip, a wedged server) left the fingerprint unrecorded, so the
            // next attempt was still treated as first contact and trusted
            // whatever key it was shown. The trust-on-first-use window has to
            // close on the first successful handshake, not the first
            // successful command.
            try pinHostKeyIfNeeded(server: server, serverId: serverId, connection: established)
            let result = try await established.run(Self.shellCommand(for: action))
            try? await established.close()
            try? repo.logCommand(
                serverId: serverId, action: action.logName,
                exitCode: result.exitCode,
                outputExcerpt: Self.loggableExcerpt(of: result, for: action)
            )
            return result
        } catch {
            if let connection { try? await connection.close() }
            try? repo.logCommand(serverId: serverId, action: action.logName, exitCode: nil, outputExcerpt: String(String(describing: error).prefix(500)))
            throw error
        }
    }

    /// What of a command's output is safe to keep in the audit trail.
    ///
    /// The audit log lives in the app's unencrypted SQLite file, which is
    /// fine for the exit codes and command names it exists to record. Server
    /// log lines are a different kind of content: they routinely carry access
    /// tokens, session identifiers and user data, none of which this app has
    /// any reason to copy onto the Mac and keep. `tailLog` output is shown in
    /// the Logs tab and then forgotten, and the audit row still records that
    /// the read happened, against which path, and whether it worked.
    static func loggableExcerpt(of result: SSHCommandResult, for action: RemoteAction) -> String? {
        if case .tailLog = action {
            return result.succeeded ? nil : String(result.stderr.prefix(500))
        }
        return String((result.succeeded ? result.stdout : result.stderr).prefix(500))
    }

    private func requireAuthorized(_ action: RemoteAction, serverId: Int64) throws {
        let allowlist = try repo.allowlist(serverId: serverId)
        switch action {
        case .serviceStatus(let name), .serviceStart(let name), .serviceStop(let name), .serviceRestart(let name):
            guard Self.isValidServiceName(name) else { throw RemoteCommandExecutorError.invalidAllowlistValue(name) }
            guard allowlist.contains(where: { $0.kind == .service && $0.value == name }) else {
                throw RemoteCommandExecutorError.notAllowlisted(name)
            }
        case .nginxTest:
            guard allowlist.contains(where: { $0.kind == .nginxConfigPath }) else {
                throw RemoteCommandExecutorError.notAllowlisted("nginx (no config path allowlisted)")
            }
        case .nginxReload:
            guard allowlist.contains(where: { $0.kind == .service && $0.value == "nginx" }) else {
                throw RemoteCommandExecutorError.notAllowlisted("nginx (not in the service allowlist)")
            }
        case .tailLog(let path, _):
            guard Self.isValidLogPath(path) else { throw RemoteCommandExecutorError.invalidAllowlistValue(path) }
            guard allowlist.contains(where: { $0.kind == .logPath && $0.value == path }) else {
                throw RemoteCommandExecutorError.notAllowlisted(path)
            }
        case .diskUsage, .memoryUsage, .uptime, .cpuUsage, .osInfo:
            break // see RemoteAction.diskUsage's doc comment — nothing to check against.
        }
    }

    /// Ubuntu/Debian's `systemctl` (D3 in the plan) — `sudo` is required for
    /// every mutating call and assumes the server's sudoers is configured
    /// for passwordless, per-command NOPASSWD entries (see the plan's "Rủi
    /// ro kỹ thuật" section), not a blanket `sudo` grant. `tailLog`
    /// deliberately does **not** use `sudo`: a NOPASSWD sudoers wildcard for
    /// `tail` on an arbitrary path is a bigger privilege-escalation surface
    /// than it's worth for read-only log access — the setup guide instead
    /// tells the user to add the SSH user to the `adm` group, which already
    /// has read access to `/var/log` on Debian/Ubuntu by default.
    private static func shellCommand(for action: RemoteAction) -> String {
        switch action {
        case .serviceStatus(let name): "systemctl is-active \(name)"
        case .serviceStart(let name): "sudo systemctl start \(name)"
        case .serviceStop(let name): "sudo systemctl stop \(name)"
        case .serviceRestart(let name): "sudo systemctl restart \(name)"
        case .nginxTest: "sudo nginx -t"
        case .nginxReload: "sudo systemctl reload nginx"
        case .tailLog(let path, let lines): "tail -n \(clampedTailLines(lines)) \(path)"
        case .diskUsage: "df -h /"
        case .memoryUsage: "free -m"
        case .uptime: "uptime"
        // Two samples 0.5s apart — `top`'s first batch-mode iteration
        // compares against cumulative time since boot, not a live rate.
        case .cpuUsage: #"top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1"#
        case .osInfo: "uname -sr; grep PRETTY_NAME /etc/os-release 2>/dev/null"
        }
    }

    // MARK: - Resource stats (parsed)

    public func diskUsage(on server: RemoteServer) async throws -> RemoteDiskUsage {
        let result = try await execute(.diskUsage, on: server)
        guard let parsed = Self.parseDiskUsage(result.stdout) else {
            throw RemoteCommandExecutorError.parseFailure("df output")
        }
        return parsed
    }

    public func memoryUsage(on server: RemoteServer) async throws -> RemoteMemoryUsage {
        let result = try await execute(.memoryUsage, on: server)
        guard let parsed = Self.parseMemoryUsage(result.stdout) else {
            throw RemoteCommandExecutorError.parseFailure("free output")
        }
        return parsed
    }

    public func uptime(on server: RemoteServer) async throws -> RemoteUptime {
        let result = try await execute(.uptime, on: server)
        return Self.parseUptime(result.stdout)
    }

    public func cpuUsage(on server: RemoteServer) async throws -> RemoteCPUUsage {
        let result = try await execute(.cpuUsage, on: server)
        guard let parsed = Self.parseCPUUsage(result.stdout) else {
            throw RemoteCommandExecutorError.parseFailure("top output")
        }
        return parsed
    }

    public func osInfo(on server: RemoteServer) async throws -> RemoteOSInfo {
        let result = try await execute(.osInfo, on: server)
        return Self.parseOSInfo(result.stdout)
    }

    /// Parses `df -h /`'s second line:
    /// ```
    /// Filesystem      Size  Used Avail Use% Mounted on
    /// /dev/sda1        20G  8.0G   11G  43% /
    /// ```
    static func parseDiskUsage(_ output: String) -> RemoteDiskUsage? {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 5 else { return nil }
        return RemoteDiskUsage(size: fields[1], used: fields[2], available: fields[3], usePercent: fields[4])
    }

    /// Parses `free -m`'s `Mem:` (and, if present, `Swap:`) line:
    /// ```
    ///               total        used        free      shared  buff/cache   available
    /// Mem:           7955        1234         123          45        6598        6500
    /// Swap:          2047           0        2047
    /// ```
    static func parseMemoryUsage(_ output: String) -> RemoteMemoryUsage? {
        let lines = output.split(separator: "\n")
        guard let memLine = lines.first(where: { $0.hasPrefix("Mem:") }) else { return nil }
        let fields = memLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4,
              let total = Int(fields[1]), let used = Int(fields[2]), let free = Int(fields[3])
        else { return nil }
        let available = fields.count >= 7 ? Int(fields[6]) : nil

        var swapTotal: Int?
        var swapUsed: Int?
        if let swapLine = lines.first(where: { $0.hasPrefix("Swap:") }) {
            let swapFields = swapLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if swapFields.count >= 3 {
                swapTotal = Int(swapFields[1])
                swapUsed = Int(swapFields[2])
            }
        }
        return RemoteMemoryUsage(totalMB: total, usedMB: used, freeMB: free, availableMB: available, swapTotalMB: swapTotal, swapUsedMB: swapUsed)
    }

    /// Parses `top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1`, e.g.:
    /// ```
    /// %Cpu(s):  2.3 us,  1.2 sy,  0.0 ni, 96.0 id,  0.3 wa,  0.0 hi,  0.1 si,  0.0 st
    /// ```
    /// Busy % is derived from idle (`100 - id`) rather than summing `us`/`sy`
    /// — `id` is always present across `procps` versions, while the exact
    /// set of other fields (`ni`/`wa`/`hi`/`si`/`st`) varies.
    static func parseCPUUsage(_ output: String) -> RemoteCPUUsage? {
        guard let match = output.range(of: #"([0-9]+\.[0-9]+)\s*id"#, options: .regularExpression) else { return nil }
        let idleText = output[match].split(separator: " ").first.map(String.init) ?? ""
        guard let idle = Double(idleText) else { return nil }
        return RemoteCPUUsage(busyPercent: max(0, min(100, 100 - idle)))
    }

    /// Parses `uname -sr` (first line) + `/etc/os-release`'s
    /// `PRETTY_NAME="..."` line (second line, if present — e.g. absent on a
    /// minimal/non-Linux target where that file doesn't exist).
    static func parseOSInfo(_ output: String) -> RemoteOSInfo {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let kernel = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let prettyName = lines.dropFirst().first(where: { $0.hasPrefix("PRETTY_NAME=") })
            .map { $0.replacingOccurrences(of: "PRETTY_NAME=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        return RemoteOSInfo(kernel: kernel, prettyName: prettyName)
    }

    /// Parses `uptime`'s `load average: 0.08, 0.03, 0.01` suffix (also
    /// accepts BSD/macOS's `load averages:` spelling).
    static func parseUptime(_ output: String) -> RemoteUptime {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"load averages?: ?"#, options: .regularExpression) else {
            return RemoteUptime(raw: trimmed, loadAverages: [])
        }
        let loads = trimmed[range.upperBound...]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return RemoteUptime(raw: trimmed, loadAverages: loads)
    }

    // MARK: - Nginx config (SFTP read/write)

    /// Not a `RemoteAction` case — file content doesn't fit that type's
    /// "runs a fixed shell command, returns exit code + stdout/stderr"
    /// shape, so it gets its own pair of methods instead of forcing an
    /// awkward result type onto every other action.
    public func readConfig(path: String, on server: RemoteServer) async throws -> String {
        let serverId = try requireSavedId(server)
        try requireConfigPathAuthorized(path, serverId: serverId)

        var connection: SSHConnection?
        do {
            let established = try await connect(server: server, forMutatingAction: false)
            connection = established
            // Before the read, for the reason spelled out in `execute`.
            try pinHostKeyIfNeeded(server: server, serverId: serverId, connection: established)
            let content = try await established.readFile(path)
            try? await established.close()
            try? repo.logCommand(serverId: serverId, action: "readFile(\(path))", exitCode: 0, outputExcerpt: nil)
            return content
        } catch {
            if let connection { try? await connection.close() }
            try? repo.logCommand(serverId: serverId, action: "readFile(\(path))", exitCode: nil, outputExcerpt: String(String(describing: error).prefix(500)))
            throw error
        }
    }

    public func writeConfig(path: String, content: String, on server: RemoteServer) async throws {
        let serverId = try requireSavedId(server)
        try requireConfigPathAuthorized(path, serverId: serverId)

        var connection: SSHConnection?
        do {
            let established = try await connect(server: server, forMutatingAction: true)
            connection = established
            // Before the write, for the reason spelled out in `execute`.
            try pinHostKeyIfNeeded(server: server, serverId: serverId, connection: established)
            try await established.writeFile(path, content: content)
            try? await established.close()
            try? repo.logCommand(serverId: serverId, action: "writeFile(\(path))", exitCode: 0, outputExcerpt: nil)
        } catch {
            if let connection { try? await connection.close() }
            try? repo.logCommand(serverId: serverId, action: "writeFile(\(path))", exitCode: nil, outputExcerpt: String(String(describing: error).prefix(500)))
            throw error
        }
    }

    private func requireConfigPathAuthorized(_ path: String, serverId: Int64) throws {
        guard Self.isValidConfigPath(path) else { throw RemoteCommandExecutorError.invalidAllowlistValue(path) }
        let allowlist = try repo.allowlist(serverId: serverId)
        guard allowlist.contains(where: { $0.kind == .nginxConfigPath && $0.value == path }) else {
            throw RemoteCommandExecutorError.notAllowlisted(path)
        }
    }

    // MARK: - Shared

    private func requireSavedId(_ server: RemoteServer) throws -> Int64 {
        guard let id = server.id else { throw RemoteCommandExecutorError.serverNotSaved }
        return id
    }

    private func connect(server: RemoteServer, forMutatingAction: Bool) async throws -> SSHConnection {
        let credential = try repo.credential(for: server, forMutatingAction: forMutatingAction)
        return try await SSHCommandRunner.connect(
            host: server.host, port: server.port, username: server.username,
            credential: credential, pinnedHostKeyFingerprint: server.hostKeyFingerprint
        )
    }

    private func pinHostKeyIfNeeded(server: RemoteServer, serverId: Int64, connection: SSHConnection) throws {
        guard server.hostKeyFingerprint == nil else { return }
        try repo.recordHostKeyFingerprint(id: serverId, fingerprint: connection.hostKeyFingerprint)
    }
}
