import Foundation

public enum RemoteResource: String, Sendable, Equatable, CaseIterable {
    case cpu, memory, disk

    /// Used in the alert title the user reads.
    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .disk: "Ổ đĩa"
        }
    }

    /// Part of the `app_settings` flag key that remembers whether this
    /// server is already in an alerted state for this resource.
    public var alertFlagName: String { rawValue }
}

public struct RemoteResourceBreach: Sendable, Equatable {
    public let resource: RemoteResource
    public let percent: Double
    public let threshold: Int
}

/// The thresholds, all as whole percentages, with 0 meaning "don't alert on
/// this" — the same convention the local temperature and battery thresholds
/// already use.
public struct RemoteResourceThresholds: Sendable, Equatable {
    public var cpuPercent: Int
    public var memoryPercent: Int
    public var diskPercent: Int

    public init(cpuPercent: Int, memoryPercent: Int, diskPercent: Int) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.diskPercent = diskPercent
    }

    public var allDisabled: Bool {
        cpuPercent <= 0 && memoryPercent <= 0 && diskPercent <= 0
    }
}

/// Turns a stats reading into the list of thresholds it crosses.
///
/// Pure on purpose: deciding what counts as "too high" is the part worth
/// testing, and it shouldn't need an SSH connection to exercise.
public enum RemoteResourceAlerts {
    public static func breaches(
        in stats: RemoteServerStats, thresholds: RemoteResourceThresholds
    ) -> [RemoteResourceBreach] {
        var found: [RemoteResourceBreach] = []

        if thresholds.cpuPercent > 0, let cpu = stats.cpu, cpu.busyPercent >= Double(thresholds.cpuPercent) {
            found.append(RemoteResourceBreach(resource: .cpu, percent: cpu.busyPercent, threshold: thresholds.cpuPercent))
        }
        if thresholds.memoryPercent > 0, let memory = stats.memory, let percent = memoryPercent(memory),
           percent >= Double(thresholds.memoryPercent) {
            found.append(RemoteResourceBreach(resource: .memory, percent: percent, threshold: thresholds.memoryPercent))
        }
        if thresholds.diskPercent > 0, let disk = stats.disk, let percent = diskPercent(disk),
           percent >= Double(thresholds.diskPercent) {
            found.append(RemoteResourceBreach(resource: .disk, percent: percent, threshold: thresholds.diskPercent))
        }
        return found
    }

    /// Memory pressure measured against `available`, not `used`.
    ///
    /// `free -m`'s `used` column excludes buffers and cache, which Linux
    /// hands back the moment anything needs them — a server sitting at 90%
    /// "used" by that definition may have plenty of room, and one at 40% may
    /// not. `available` is the kernel's own estimate of what a new process
    /// could actually get, so it's the figure worth alerting on. Falls back
    /// to `used` only when the column is missing, which is what older
    /// `procps` builds do.
    static func memoryPercent(_ usage: RemoteMemoryUsage) -> Double? {
        guard usage.totalMB > 0 else { return nil }
        if let available = usage.availableMB {
            return Double(usage.totalMB - available) / Double(usage.totalMB) * 100
        }
        return Double(usage.usedMB) / Double(usage.totalMB) * 100
    }

    /// `df -h` reports use as a string like `"43%"`.
    static func diskPercent(_ usage: RemoteDiskUsage) -> Double? {
        Double(usage.usePercent.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// The alert text. Whole percentages, because a server reported as
    /// "87.3% full" invites a precision the readings don't have.
    public static func alertBody(_ breach: RemoteResourceBreach) -> String {
        "\(Int(breach.percent.rounded()))% (ngưỡng \(breach.threshold)%)"
    }
}
