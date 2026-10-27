import Foundation

/// The values behind one overlay refresh. Every field is optional: `nil`
/// means this Mac has no reading for it (no fan, no battery, an SMC key that
/// does not exist on this chip) and the row is hidden, rather than showing a
/// zero that looks like a real measurement.
public struct OverlaySample: Sendable, Equatable {
    public var cpuPercent: Double?
    public var cpuTempCelsius: Double?
    public var gpuPercent: Double?
    public var gpuTempCelsius: Double?
    public var gpuMemoryMB: UInt64?
    public var ramUsedMB: UInt64?
    public var ramTotalMB: UInt64?
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    /// Colours the memory row, which "% used" alone would do misleadingly.
    public var memoryPressureLevel: Int32?
    public var swapUsedMB: UInt64?
    public var downloadKbps: Double?
    public var uploadKbps: Double?
    /// Empty on fanless Macs.
    public var fanRPMs: [Double]
    public var batteryPercent: Double?
    public var batteryCharging: Bool?
    public var systemPowerWatts: Double?
    /// Filled by the app from the screen the overlay is on, not by the
    /// sampler: `NSScreen` is main-thread only.
    public var displayHz: Int?
    public var uptimeSecs: UInt64?

    public init(
        cpuPercent: Double? = nil, cpuTempCelsius: Double? = nil,
        gpuPercent: Double? = nil, gpuTempCelsius: Double? = nil, gpuMemoryMB: UInt64? = nil,
        ramUsedMB: UInt64? = nil, ramTotalMB: UInt64? = nil, memoryPressureLevel: Int32? = nil,
        swapUsedMB: UInt64? = nil, downloadKbps: Double? = nil, uploadKbps: Double? = nil,
        fanRPMs: [Double] = [], batteryPercent: Double? = nil, batteryCharging: Bool? = nil,
        systemPowerWatts: Double? = nil, displayHz: Int? = nil, uptimeSecs: UInt64? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.cpuTempCelsius = cpuTempCelsius
        self.gpuPercent = gpuPercent
        self.gpuTempCelsius = gpuTempCelsius
        self.gpuMemoryMB = gpuMemoryMB
        self.ramUsedMB = ramUsedMB
        self.ramTotalMB = ramTotalMB
        self.memoryPressureLevel = memoryPressureLevel
        self.swapUsedMB = swapUsedMB
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
        self.fanRPMs = fanRPMs
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.systemPowerWatts = systemPowerWatts
        self.displayHz = displayHz
        self.uptimeSecs = uptimeSecs
    }
}

/// Fixed-size history for the overlay's sparklines. The overlay appends once
/// a second for as long as it is on, so this overwrites in place instead of
/// the `append` + `removeFirst` the System pane uses, which shifts the whole
/// array on every sample.
public struct OverlayRing: Sendable, Equatable {
    public let capacity: Int
    private var storage: [Double] = []
    /// Where the next value goes once `storage` is full.
    private var head = 0

    public init(capacity: Int = 60) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    public var values: [Double] {
        Array(storage[head...] + storage[..<head])
    }
}
