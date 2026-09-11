import Foundation

/// Every action the app can ever ask a remote server to perform — this is
/// the *entire* menu (docs/remote-server-management-plan.md's "no free-form
/// shell command" principle). Adding a new capability means adding a new
/// case here and to `RemoteCommandExecutor.shellCommand(for:)`, never a
/// free-text field anywhere in the UI.
public enum RemoteAction: Sendable, Equatable {
    case serviceStatus(name: String)
    case serviceStart(name: String)
    case serviceStop(name: String)
    case serviceRestart(name: String)
    /// `sudo nginx -t` — read-only config validation, authorized by having
    /// *any* `.nginxConfigPath` allowlist entry (proves nginx management is
    /// enabled for this server) rather than a specific service/path, since
    /// it doesn't touch any single file or service.
    case nginxTest
    /// `sudo systemctl reload nginx` — authorized the same way a systemd
    /// action is (`.service`/"nginx" allowlisted), since structurally
    /// that's exactly what it is.
    case nginxReload
    /// `tail -n <lines> <path>` — read-only, `path` must be in the server's
    /// `.logPath` allowlist.
    case tailLog(path: String, lines: Int)
    /// `df -h /`, `free -m`, `uptime` — fixed, parameter-less, read-only
    /// commands with no server-specific value to allowlist (unlike every
    /// other case here), so `RemoteCommandExecutor` authorizes them
    /// unconditionally rather than checking against an allowlist entry.
    case diskUsage
    case memoryUsage
    case uptime
    /// `top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1` — fixed, parameter-less,
    /// read-only, same authorization treatment as `diskUsage`/`memoryUsage`.
    case cpuUsage
    /// `uname -sr` + `/etc/os-release`'s `PRETTY_NAME`.
    case osInfo

    /// Whether this action changes server state — governs which Keychain
    /// read (`readForMutatingAction` vs `readForStatusCheck`) is used, and
    /// the UI requires a confirm dialog before calling it.
    public var isMutating: Bool {
        switch self {
        case .serviceStatus, .nginxTest, .tailLog, .diskUsage, .memoryUsage, .uptime, .cpuUsage, .osInfo: false
        case .serviceStart, .serviceStop, .serviceRestart, .nginxReload: true
        }
    }

    /// Logged into `remote_command_log.action` — a stable, human-diffable
    /// name, not the actual shell command (an implementation detail that can
    /// change between app versions without invalidating old log rows).
    public var logName: String {
        switch self {
        case .serviceStatus(let name): "serviceStatus(\(name))"
        case .serviceStart(let name): "serviceStart(\(name))"
        case .serviceStop(let name): "serviceStop(\(name))"
        case .serviceRestart(let name): "serviceRestart(\(name))"
        case .nginxTest: "nginxTest"
        case .nginxReload: "nginxReload"
        case .tailLog(let path, let lines): "tailLog(\(path), \(lines))"
        case .diskUsage: "diskUsage"
        case .memoryUsage: "memoryUsage"
        case .uptime: "uptime"
        case .cpuUsage: "cpuUsage"
        case .osInfo: "osInfo"
        }
    }

    /// Shown in the UI's confirm dialog before a mutating action runs.
    public var confirmationMessage: String? {
        switch self {
        case .serviceStatus, .nginxTest, .tailLog, .diskUsage, .memoryUsage, .uptime, .cpuUsage, .osInfo: nil
        case .serviceStart(let name): "Start the \(name) service?"
        case .serviceStop(let name): "Stop the \(name) service? This may take the server offline."
        case .serviceRestart(let name): "Restart the \(name) service? This may cause a brief interruption."
        case .nginxReload: "Reload nginx? This applies the current config on disk immediately."
        }
    }
}
