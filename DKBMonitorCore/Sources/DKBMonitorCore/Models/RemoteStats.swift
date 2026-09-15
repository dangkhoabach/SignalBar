import Foundation

public struct RemoteDiskUsage: Sendable, Equatable {
    public let size: String
    public let used: String
    public let available: String
    public let usePercent: String
}

public struct RemoteMemoryUsage: Sendable, Equatable {
    public let totalMB: Int
    public let usedMB: Int
    public let freeMB: Int
    public let availableMB: Int?
    /// From `free -m`'s `Swap:` line — `nil` on a server with no swap
    /// configured (that line's total reads `0`, which parses fine, but a
    /// server where the line is missing entirely also degrades to `nil`
    /// rather than failing the whole parse).
    public let swapTotalMB: Int?
    public let swapUsedMB: Int?

    public init(
        totalMB: Int, usedMB: Int, freeMB: Int, availableMB: Int? = nil,
        swapTotalMB: Int? = nil, swapUsedMB: Int? = nil
    ) {
        self.totalMB = totalMB
        self.usedMB = usedMB
        self.freeMB = freeMB
        self.availableMB = availableMB
        self.swapTotalMB = swapTotalMB
        self.swapUsedMB = swapUsedMB
    }
}

public struct RemoteUptime: Sendable, Equatable {
    public let raw: String
    public let loadAverages: [Double]
}

/// From `top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1` — two samples half a
/// second apart (the first batch-mode iteration of `top` compares against
/// cumulative time since boot, not a live rate, so it's discarded).
public struct RemoteCPUUsage: Sendable, Equatable {
    public let busyPercent: Double
}

/// From `uname -sr` + `/etc/os-release`'s `PRETTY_NAME` — static server
/// identity info, not something that changes between refreshes, but shown
/// alongside the other stats since there's nowhere else in the UI for it.
public struct RemoteOSInfo: Sendable, Equatable {
    public let kernel: String
    public let prettyName: String?
}

/// Every reading the server detail pane shows, gathered in one pass.
///
/// All optional and failures kept alongside rather than thrown, because
/// these are five independent commands: a box without `top` installed still
/// has a disk and a memory figure worth showing, and losing those to an
/// unrelated failure is worse than showing four values and one message.
public struct RemoteServerStats: Sendable, Equatable {
    public var disk: RemoteDiskUsage?
    public var memory: RemoteMemoryUsage?
    public var uptime: RemoteUptime?
    public var cpu: RemoteCPUUsage?
    public var os: RemoteOSInfo?
    /// One entry per reading that couldn't be taken, already phrased for
    /// display and prefixed with which reading it was.
    public var failures: [String] = []

    public init() {}
}
