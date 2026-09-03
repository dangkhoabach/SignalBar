import Foundation

/// A snapshot of machine state — CPU/RAM/swap/disk/network/GPU/battery/fans —
/// for the menu bar/System pane UI (Phase 7/11) and for the Scheduler's
/// temperature/battery alerts (Phase 4). Fields that don't apply to a given
/// Mac (no fan, no battery, GPU % unavailable) are `nil`/empty rather than a
/// sentinel value, mirroring the Rust `SystemStats` struct's optionality.
public struct SystemStats: Sendable, Equatable {
    public var cpuPercent: Double
    public var cpuCores: [Double]
    public var ramUsedMB: UInt64
    public var ramTotalMB: UInt64
    public var swapUsedMB: UInt64
    public var swapTotalMB: UInt64
    public var diskUsedGB: Double
    public var diskTotalGB: Double
    public var gpuName: String?
    public var gpuPercent: Double?
    public var networkConnected: Bool
    /// Hardware port name, e.g. "Wi-Fi" or "Ethernet".
    public var networkType: String?
    /// Wi-Fi SSID; always `nil` for wired connections.
    public var networkName: String?
    /// LAN-side IPv4 address of the active interface (never the public IP).
    public var networkLocalIP: String?
    /// KB/s received across all non-loopback interfaces since the previous poll.
    public var networkDownloadKbps: Double
    /// KB/s transmitted across all non-loopback interfaces since the previous poll.
    public var networkUploadKbps: Double
    /// Highest reading among the SoC/CPU die temperature sensors, in Celsius.
    public var cpuTempCelsius: Double?
    public var batteryPercent: Double?
    /// `true` while the battery is filling or the machine is on AC with a full
    /// battery; `nil` on machines with no battery (desktops).
    public var batteryCharging: Bool?
    public var uptimeSecs: UInt64
    /// Current RPM of each fan. Empty on machines where fan speed isn't
    /// readable (fanless models, or the SMC key set not matching).
    public var fanRPMs: [Double]

    public init(
        cpuPercent: Double = 0, cpuCores: [Double] = [],
        ramUsedMB: UInt64 = 0, ramTotalMB: UInt64 = 0,
        swapUsedMB: UInt64 = 0, swapTotalMB: UInt64 = 0,
        diskUsedGB: Double = 0, diskTotalGB: Double = 0,
        gpuName: String? = nil, gpuPercent: Double? = nil,
        networkConnected: Bool = false, networkType: String? = nil, networkName: String? = nil, networkLocalIP: String? = nil,
        networkDownloadKbps: Double = 0, networkUploadKbps: Double = 0,
        cpuTempCelsius: Double? = nil, batteryPercent: Double? = nil, batteryCharging: Bool? = nil,
        uptimeSecs: UInt64 = 0, fanRPMs: [Double] = []
    ) {
        self.cpuPercent = cpuPercent
        self.cpuCores = cpuCores
        self.ramUsedMB = ramUsedMB
        self.ramTotalMB = ramTotalMB
        self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB
        self.diskUsedGB = diskUsedGB
        self.diskTotalGB = diskTotalGB
        self.gpuName = gpuName
        self.gpuPercent = gpuPercent
        self.networkConnected = networkConnected
        self.networkType = networkType
        self.networkName = networkName
        self.networkLocalIP = networkLocalIP
        self.networkDownloadKbps = networkDownloadKbps
        self.networkUploadKbps = networkUploadKbps
        self.cpuTempCelsius = cpuTempCelsius
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.uptimeSecs = uptimeSecs
        self.fanRPMs = fanRPMs
    }
}

/// Implemented by the app target using Mach/IOKit/CoreWLAN-adjacent system
/// calls — cannot live in this package, which deliberately links no system
/// frameworks beyond Foundation/Security (see D6 in the port plan).
public protocol SystemStatsProvider: Sendable {
    func snapshot() async -> SystemStats

    /// Cheap subset (CPU/RAM/temperature/battery only) for callers that poll
    /// frequently but never display network/GPU/disk/swap/fan fields — skips
    /// the `Process` spawns (`route`/`networksetup`/`ifconfig`/`ioreg`) those
    /// fields require. Defaults to the full `snapshot()` so existing
    /// conformers (test doubles) don't need to implement it.
    func snapshotLight() async -> SystemStats
}

extension SystemStatsProvider {
    public func snapshotLight() async -> SystemStats {
        await snapshot()
    }
}
