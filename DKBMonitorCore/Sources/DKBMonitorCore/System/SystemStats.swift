import Foundation

/// A snapshot of machine state — CPU/RAM/swap/disk/network/GPU/battery/fans —
/// for the menu bar/System pane UI (Phase 7/11) and for the Scheduler's
/// temperature/battery alerts (Phase 4). Fields that don't apply to a given
/// Mac (no fan, no battery, GPU % unavailable) are `nil`/empty rather than a
/// sentinel value, mirroring the Rust `SystemStats` struct's optionality.
public struct SystemStats: Sendable, Equatable {
    public var cpuPercent: Double
    public var cpuCores: [Double]
    /// Performance-level layout of `cpuCores`, so the per-core bars can be
    /// grouped and labelled E1…/P1… instead of being anonymous.
    public var cpuTopology: CPUTopology
    public var ramUsedMB: UInt64
    public var ramTotalMB: UInt64
    public var swapUsedMB: UInt64
    public var swapTotalMB: UInt64
    /// Activity-Monitor-style breakdown of `ramUsedMB`. Zero when the Mach
    /// VM statistics call fails; the three always sum to `ramUsedMB`.
    public var ramAppMB: UInt64
    public var ramWiredMB: UInt64
    public var ramCompressedMB: UInt64
    /// File-backed + purgeable pages — cached files, *not* counted as used.
    public var ramCachedMB: UInt64
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    /// The number macOS itself acts on — far more meaningful than "% used",
    /// which sits near 100% on a healthy Mac because of the file cache.
    public var memoryPressureLevel: Int32
    public var diskUsedGB: Double
    public var diskTotalGB: Double
    /// Every mounted browsable volume, internal first. `diskUsedGB`/
    /// `diskTotalGB` above stay as the boot volume's figures.
    public var volumes: [VolumeUsage]
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
    /// Derived from `temperatures` when the machine exposes sensors through
    /// the HID event system, falling back to a direct SMC key read.
    public var cpuTempCelsius: Double?
    /// Every thermal sensor this Mac exposes. Empty on machines where none
    /// are readable — `cpuTempCelsius` may still be set from SMC in that case.
    public var temperatures: [TemperatureReading]
    /// `ProcessInfo.ThermalState`'s raw value (0 nominal … 3 critical).
    /// Not the enum itself: `ProcessInfo` is Foundation, but the enum isn't
    /// `Codable`/stable enough to be worth re-exporting from this package.
    public var thermalStateRawValue: Int
    public var batteryPercent: Double?
    /// `true` while the battery is filling or the machine is on AC with a full
    /// battery; `nil` on machines with no battery (desktops).
    public var batteryCharging: Bool?
    public var uptimeSecs: UInt64
    /// Current RPM of each fan. Empty on machines where fan speed isn't
    /// readable (fanless models, or the SMC key set not matching).
    public var fanRPMs: [Double]

    public init(
        cpuPercent: Double = 0, cpuCores: [Double] = [], cpuTopology: CPUTopology = .flat(coreCount: 0),
        ramUsedMB: UInt64 = 0, ramTotalMB: UInt64 = 0,
        swapUsedMB: UInt64 = 0, swapTotalMB: UInt64 = 0,
        ramAppMB: UInt64 = 0, ramWiredMB: UInt64 = 0, ramCompressedMB: UInt64 = 0, ramCachedMB: UInt64 = 0,
        memoryPressureLevel: Int32 = 1,
        diskUsedGB: Double = 0, diskTotalGB: Double = 0, volumes: [VolumeUsage] = [],
        gpuName: String? = nil, gpuPercent: Double? = nil,
        networkConnected: Bool = false, networkType: String? = nil, networkName: String? = nil, networkLocalIP: String? = nil,
        networkDownloadKbps: Double = 0, networkUploadKbps: Double = 0,
        cpuTempCelsius: Double? = nil, temperatures: [TemperatureReading] = [], thermalStateRawValue: Int = 0,
        batteryPercent: Double? = nil, batteryCharging: Bool? = nil,
        uptimeSecs: UInt64 = 0, fanRPMs: [Double] = []
    ) {
        self.cpuPercent = cpuPercent
        self.cpuCores = cpuCores
        self.cpuTopology = cpuTopology
        self.ramUsedMB = ramUsedMB
        self.ramTotalMB = ramTotalMB
        self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB
        self.ramAppMB = ramAppMB
        self.ramWiredMB = ramWiredMB
        self.ramCompressedMB = ramCompressedMB
        self.ramCachedMB = ramCachedMB
        self.memoryPressureLevel = memoryPressureLevel
        self.diskUsedGB = diskUsedGB
        self.diskTotalGB = diskTotalGB
        self.volumes = volumes
        self.gpuName = gpuName
        self.gpuPercent = gpuPercent
        self.networkConnected = networkConnected
        self.networkType = networkType
        self.networkName = networkName
        self.networkLocalIP = networkLocalIP
        self.networkDownloadKbps = networkDownloadKbps
        self.networkUploadKbps = networkUploadKbps
        self.cpuTempCelsius = cpuTempCelsius
        self.temperatures = temperatures
        self.thermalStateRawValue = thermalStateRawValue
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
