import Darwin
import Foundation
import IOKit.ps
import DKBMonitorCore

/// Native replacement for `sysstats.rs`. Where a real public API exists
/// (Mach host stats for CPU/RAM/swap, `statfs` for disk, `getifaddrs` for
/// throughput, `IOPowerSources` for battery, the `IOAccelerator` registry
/// entry for GPU load) this uses it directly. Where
/// Apple exposes no public API at all — GPU name, active network
/// interface/Wi-Fi SSID/local IP — this shells out via `Process`, the exact
/// same commands the Rust version used (`system_profiler`,
/// `route`/`networksetup`/`ifconfig`); those aren't shortcuts, they're
/// genuinely the only source, same as Apple's own menu-bar utilities.
///
/// Deliberately keeps the Rust version's `networksetup`-based Wi-Fi SSID
/// lookup instead of `CoreWLAN` (`CWInterface.ssid()`): since macOS 10.15,
/// that API requires Location Services authorization, which would add a
/// permission prompt (and an Info.plist usage-description string) to a
/// system monitor app for a single display field. Not worth the privacy
/// footprint for a value `networksetup` already reports without any prompt.
public actor SystemStatsService: SystemStatsProvider {
    private let smc = SMCReader()
    private var smcOpened = false
    private var smcOpenAttempted = false

    /// Created on first use, not in `init`: it holds one HID service client
    /// per sensor (50+ on Apple Silicon), which isn't worth allocating for a
    /// caller that only ever asks for `snapshotLight()`'s CPU/RAM figures.
    private var hidThermal: HIDThermalReader?
    private var hidThermalLoaded = false

    private var previousCoreTicks: [[UInt32]]?
    private var previousNetworkBytes: (received: UInt64, transmitted: UInt64)?
    private var previousNetworkPollDate: Date?
    private var gpuNameFetched = false
    private var cachedGPUName: String?

    /// `networkStatus()` shells out to `route`/`networksetup` (up to 3
    /// process spawns) to resolve the active interface/SSID — values that
    /// essentially never change between polls. Callers like `SystemView`
    /// poll every 2s, so re-resolving this on every single poll would fork
    /// a handful of processes 30x/minute for no benefit; cached and only
    /// re-resolved once this TTL elapses.
    private static let networkStatusTTL: TimeInterval = 30
    private var cachedNetworkStatus: (connected: Bool, type: String?, name: String?, localIP: String?)?
    private var networkStatusFetchedAt: Date?

    /// GPU load read in-process from IOKit. This replaced forking `ioreg`
    /// every 1.5s while the System pane was open.
    private let gpuStats = GPUStatsReader()

    /// SMC keys for the overlay's readings, probed once: which per-generation
    /// temperature key exists never changes on a given Mac, and each probe
    /// miss is a full SMC round trip.
    private struct OverlaySensorKeys {
        var cpuTemp: String?
        var gpuTemp: String?
        var power: String?
        var fanCount = 0
    }
    private var overlaySensorKeys: OverlaySensorKeys?

    private var batteryServiceProbed = false
    private var batteryService: io_service_t = 0

    public init() {}

    /// CPU/RAM/temperature/battery only — no `Process` spawns. Used by
    /// callers (menu bar, scheduler system alerts) that poll frequently but
    /// never surface network/GPU/disk/swap/fan fields.
    public func snapshotLight() async -> SystemStats {
        ensureSMCOpen()
        let (cpuPercent, cpuCores) = cpuUsage()
        let memory = memoryUsage()
        let battery = batteryStatus()
        // Deliberately skips `temperatures()`: walking 50+ HID sensors costs
        // far more than the rest of this method combined, and the only
        // consumers of the light snapshot (menu bar, scheduler alerts) read
        // the single `cpuTempCelsius` value, which SMC supplies on its own.
        return SystemStats(
            cpuPercent: cpuPercent, cpuCores: cpuCores, cpuTopology: Self.cpuTopology,
            ramUsedMB: memory.usedMB, ramTotalMB: memory.totalMB,
            cpuTempCelsius: cpuTempCelsius(from: []),
            batteryPercent: battery.percent, batteryCharging: battery.charging
        )
    }

    public func snapshot() async -> SystemStats {
        ensureSMCOpen()

        let (cpuPercent, cpuCores) = cpuUsage()
        let memory = memoryUsage()
        let (swapUsed, swapTotal) = swapUsageMB()
        let (diskUsed, diskTotal) = diskUsageGB()
        let network = networkStatus()
        let (downloadKbps, uploadKbps) = networkThroughputKbps()
        let battery = batteryStatus()
        let readings = temperatures()

        return SystemStats(
            cpuPercent: cpuPercent, cpuCores: cpuCores, cpuTopology: Self.cpuTopology,
            ramUsedMB: memory.usedMB, ramTotalMB: memory.totalMB,
            swapUsedMB: swapUsed, swapTotalMB: swapTotal,
            ramAppMB: memory.appMB, ramWiredMB: memory.wiredMB,
            ramCompressedMB: memory.compressedMB, ramCachedMB: memory.cachedMB,
            memoryPressureLevel: memoryPressureLevel(),
            diskUsedGB: diskUsed, diskTotalGB: diskTotal, volumes: volumes(),
            gpuName: gpuName(), gpuPercent: gpuPercent(),
            networkConnected: network.connected, networkType: network.type, networkName: network.name, networkLocalIP: network.localIP,
            networkDownloadKbps: downloadKbps, networkUploadKbps: uploadKbps,
            cpuTempCelsius: cpuTempCelsius(from: readings), temperatures: readings,
            thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue,
            batteryPercent: battery.percent, batteryCharging: battery.charging,
            batteryHealth: battery.percent == nil ? nil : batteryHealth(),
            uptimeSecs: uptimeSecs(), fanRPMs: fanRPMs()
        )
    }

    /// What the always-on-top overlay shows, sampled once a second. The
    /// same rule as `snapshotLight()` — no `Process` spawns — and also none
    /// of the HID sensor walk (51 ms a sample on an M3 Pro): temperatures,
    /// fans and power are single SMC keys resolved once.
    ///
    /// CPU temperature is therefore one SMC die sensor, not the hottest of
    /// the HID sensors the System pane shows, and the two can differ by
    /// several degrees either way. On a Mac whose SMC carries none of the
    /// candidate keys the row is hidden.
    public func snapshotOverlay() async -> OverlaySample {
        ensureSMCOpen()
        let keys = resolvedOverlaySensorKeys()
        let (cpuPercent, _) = cpuUsage()
        let memory = memoryUsage()
        let gpu = gpuStats.read()
        let (download, upload) = networkThroughputKbps()
        let battery = batteryStatus()

        return OverlaySample(
            cpuPercent: cpuPercent,
            cpuTempCelsius: smcValue(keys.cpuTemp, within: 1...150),
            gpuPercent: gpu?.utilizationPercent,
            gpuTempCelsius: smcValue(keys.gpuTemp, within: 1...150),
            gpuMemoryMB: gpu?.inUseMemoryBytes.map { $0 / 1_048_576 },
            ramUsedMB: memory.usedMB, ramTotalMB: memory.totalMB,
            memoryPressureLevel: memoryPressureLevel(),
            swapUsedMB: swapUsageMB().used,
            downloadKbps: download, uploadKbps: upload,
            fanRPMs: (0..<keys.fanCount).compactMap { try? smc.readFloatValue(key: SMCReader.fanActualKey(index: $0)) },
            batteryPercent: battery.percent, batteryCharging: battery.charging,
            systemPowerWatts: smcValue(keys.power, within: 0...2000),
            uptimeSecs: uptimeSecs()
        )
    }

    private func resolvedOverlaySensorKeys() -> OverlaySensorKeys {
        if let overlaySensorKeys { return overlaySensorKeys }
        var keys = OverlaySensorKeys()
        if smcOpened {
            keys.cpuTemp = smc.firstReadableKey(in: SMCReader.candidateTempKeys, within: 1...150)
            keys.gpuTemp = smc.firstReadableKey(in: SMCReader.candidateGPUTempKeys, within: 1...150)
            keys.power = smc.firstReadableKey(in: [SMCReader.systemPowerKey], within: 0...2000)
            keys.fanCount = smc.fanCount()
        }
        overlaySensorKeys = keys
        return keys
    }

    /// A resolved key's current value, or `nil` when it reads outside
    /// `range` — a sleeping sensor reports 0 or garbage.
    private func smcValue(_ key: String?, within range: ClosedRange<Double>) -> Double? {
        guard let key, let value = try? smc.readFloatValue(key: key), range.contains(value) else { return nil }
        return value
    }

    // MARK: - CPU (Mach host_processor_info)

    private func hostProcessorCPULoadInfo() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: Int(bitPattern: infoArray)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        return infoArray.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(cpuCount)) { loads in
            (0..<Int(cpuCount)).map { i in
                let ticks = loads[i].cpu_ticks
                return [ticks.0, ticks.1, ticks.2, ticks.3] // user, system, idle, nice
            }
        }
    }

    /// Read once per process: the CPU layout is fixed hardware, so
    /// re-running four `sysctlbyname` calls on every 2s poll would be pure
    /// waste. `static` rather than an instance property so both the light
    /// and full snapshots share the one read.
    private static let cpuTopology: CPUTopology = {
        let logical = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let levelCount = sysctlInt("hw.nperflevels") ?? 1
        guard levelCount > 1 else { return .flat(coreCount: logical) }

        let levels = (0..<levelCount).compactMap { index -> CPUTopology.Level? in
            let count = sysctlInt("hw.perflevel\(index).logicalcpu") ?? 0
            guard count > 0 else { return nil }
            return CPUTopology.Level(
                index: index,
                name: sysctlString("hw.perflevel\(index).name") ?? "Level \(index)",
                coreCount: count
            )
        }
        return levels.isEmpty ? .flat(coreCount: logical) : CPUTopology(levels: levels)
    }()

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func cpuUsage() -> (percent: Double, cores: [Double]) {
        guard let ticks = hostProcessorCPULoadInfo() else { return (0, []) }
        defer { previousCoreTicks = ticks }

        guard let previous = previousCoreTicks, previous.count == ticks.count else {
            return (0, Array(repeating: 0, count: ticks.count))
        }

        var corePercents: [Double] = []
        var totalUsed: Double = 0
        var totalTicks: Double = 0
        for i in 0..<ticks.count {
            let deltaUser = Double(ticks[i][0] &- previous[i][0])
            let deltaSystem = Double(ticks[i][1] &- previous[i][1])
            let deltaIdle = Double(ticks[i][2] &- previous[i][2])
            let deltaNice = Double(ticks[i][3] &- previous[i][3])
            let used = deltaUser + deltaSystem + deltaNice
            let total = used + deltaIdle
            corePercents.append(total > 0 ? (used / total) * 100 : 0)
            totalUsed += used
            totalTicks += total
        }
        return (totalTicks > 0 ? (totalUsed / totalTicks) * 100 : 0, corePercents)
    }

    // MARK: - RAM / swap (Mach host_statistics64 + sysctl)

    private struct MemoryUsage {
        var usedMB: UInt64 = 0
        var totalMB: UInt64 = 0
        var appMB: UInt64 = 0
        var wiredMB: UInt64 = 0
        var compressedMB: UInt64 = 0
        var cachedMB: UInt64 = 0
    }

    /// Activity Monitor's "Memory Used" = App Memory + Wired + Compressed.
    ///
    /// "App Memory" is `internal_page_count` minus `purgeable_count` — the
    /// anonymous pages apps actually own. The earlier `active_count`-based
    /// formula was close but not the same number: `active` includes
    /// file-backed pages that are merely in use (which belong in Cached),
    /// so it over-reported on a machine with a warm file cache.
    private func memoryUsage() -> MemoryUsage {
        var usage = MemoryUsage()

        var totalMemory: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMemory, &totalSize, nil, 0)
        usage.totalMB = totalMemory / 1_048_576

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return usage }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize == 0 ? 4096 : pageSize)

        let purgeable = UInt64(stats.purgeable_count)
        let internalPages = UInt64(stats.internal_page_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : internalPages) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page

        usage.appMB = app / 1_048_576
        usage.wiredMB = wired / 1_048_576
        usage.compressedMB = compressed / 1_048_576
        usage.cachedMB = cached / 1_048_576
        usage.usedMB = usage.appMB + usage.wiredMB + usage.compressedMB
        return usage
    }

    /// 1 normal, 2 warning, 4 critical. Defaults to normal when the sysctl
    /// is unavailable rather than inventing a scarier value.
    private func memoryPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }

    /// Mirrors C's `struct xsw_usage` from `<sys/sysctl.h>` — field order and
    /// sizes must match exactly for `sysctlbyname` to fill it correctly.
    /// `boolean_t` is a 4-byte C `int`, not Swift's 1-byte `Bool`.
    private struct XSWUsage {
        var xsuTotal: UInt64 = 0
        var xsuAvail: UInt64 = 0
        var xsuUsed: UInt64 = 0
        var xsuPageSize: UInt32 = 0
        var xsuEncrypted: Int32 = 0
    }

    private func swapUsageMB() -> (used: UInt64, total: UInt64) {
        var usage = XSWUsage()
        var size = MemoryLayout<XSWUsage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsuUsed / 1_048_576, usage.xsuTotal / 1_048_576)
    }

    // MARK: - Disk

    private func diskUsageGB() -> (used: Double, total: Double) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0) }
        let blockSize = Double(stat.f_bsize)
        let total = Double(stat.f_blocks) * blockSize
        let available = Double(stat.f_bavail) * blockSize
        return ((total - available) / 1_073_741_824, total / 1_073_741_824)
    }

    /// Every mounted browsable volume, internal first. Uses
    /// `volumeAvailableCapacityForImportantUsage` — the figure Finder shows,
    /// which counts space reclaimable from purgeable snapshots, rather than
    /// `statfs`'s raw free blocks that read alarmingly low on APFS.
    private func volumes() -> [VolumeUsage] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsBrowsableKey, .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> VolumeUsage? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            return VolumeUsage(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: UInt64(total),
                freeBytes: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)),
                isInternal: values.volumeIsInternal ?? false
            )
        }
        .sorted { ($0.isInternal ? 0 : 1, $0.path) < ($1.isInternal ? 0 : 1, $1.path) }
    }

    // MARK: - Network throughput (getifaddrs)

    private func networkByteCounters() -> (received: UInt64, transmitted: UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var received: UInt64 = 0
        var transmitted: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0", !name.hasPrefix("Loopback"),
                  current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data
            else { continue }
            let networkData = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
            received += UInt64(networkData.ifi_ibytes)
            transmitted += UInt64(networkData.ifi_obytes)
        }
        return (received, transmitted)
    }

    /// `elapsed` is measured against the previous poll's own timestamp
    /// (rather than an assumed fixed interval), so the first poll after
    /// launch — or any poll delayed by system load — doesn't under/over-report.
    private func networkThroughputKbps() -> (download: Double, upload: Double) {
        let now = Date()
        let (received, transmitted) = networkByteCounters()
        defer {
            previousNetworkBytes = (received, transmitted)
            previousNetworkPollDate = now
        }
        guard let previous = previousNetworkBytes, let previousDate = previousNetworkPollDate else { return (0, 0) }

        let elapsed = max(now.timeIntervalSince(previousDate), 0.1)
        let deltaReceived = received >= previous.received ? received - previous.received : 0
        let deltaTransmitted = transmitted >= previous.transmitted ? transmitted - previous.transmitted : 0
        return (Double(deltaReceived) / 1024 / elapsed, Double(deltaTransmitted) / 1024 / elapsed)
    }

    // MARK: - Network identity (Process — no public API for any of this)

    private func runProcess(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func activeInterface() -> String? {
        guard let output = runProcess("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "interface: ") {
                return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func hardwarePort(for device: String) -> String? {
        guard let output = runProcess("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        var currentPort: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let range = line.range(of: "Hardware Port: ") {
                currentPort = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: "Device: "), String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) == device {
                return currentPort
            }
        }
        return nil
    }

    private func wifiSSID(for device: String) -> String? {
        guard let output = runProcess("/usr/sbin/networksetup", ["-getairportnetwork", device]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "Current Wi-Fi Network: ") else { return nil }
        return String(trimmed[range.upperBound...])
    }

    private func localIPAddress(for device: String) -> String? {
        guard let output = runProcess("/sbin/ifconfig", [device]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                return trimmed.dropFirst("inet ".count).split(separator: " ").first.map(String.init)
            }
        }
        return nil
    }

    private func networkStatus() -> (connected: Bool, type: String?, name: String?, localIP: String?) {
        if let cachedNetworkStatus, let networkStatusFetchedAt,
           Date().timeIntervalSince(networkStatusFetchedAt) < Self.networkStatusTTL {
            return cachedNetworkStatus
        }

        let resolved: (connected: Bool, type: String?, name: String?, localIP: String?)
        if let device = activeInterface() {
            let interfaceType = hardwarePort(for: device)
            let isWiFi = interfaceType?.contains("Wi-Fi") ?? false
            resolved = (true, interfaceType, isWiFi ? wifiSSID(for: device) : nil, localIPAddress(for: device))
        } else {
            resolved = (false, nil, nil, nil)
        }

        cachedNetworkStatus = resolved
        networkStatusFetchedAt = Date()
        return resolved
    }

    // MARK: - GPU (Process for the name — no public API for it)

    private func gpuName() -> String? {
        guard !gpuNameFetched else { return cachedGPUName }
        gpuNameFetched = true
        cachedGPUName = runProcess("/usr/sbin/system_profiler", ["SPDisplaysDataType"])?
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Chipset Model:") }
            .flatMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        return cachedGPUName
    }

    private func gpuPercent() -> Double? {
        gpuStats.read()?.utilizationPercent
    }

    // MARK: - Battery (IOPowerSources — public API)

    private func batteryStatus() -> (percent: Double?, charging: Bool?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return (nil, nil)
        }

        let percent: Double?
        if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
           let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 {
            percent = Double(capacity) / Double(maxCapacity) * 100
        } else {
            percent = nil
        }

        // Every state other than "on battery" (charging, full-on-AC, etc.)
        // counts as "charging" for alert purposes — matches the Rust version.
        let charging = (description[kIOPSPowerSourceStateKey] as? String).map { $0 != (kIOPSBatteryPowerValue as String) }

        return (percent, charging)
    }

    /// Cycle count and capacities come from the `AppleSmartBattery` registry
    /// entry — `IOPowerSources` does not carry them — and the time estimate
    /// and health flag from the power source description that `batteryStatus`
    /// already reads. Only the full `snapshot()` asks for this: the figures
    /// are for the System page, and the light snapshot's callers never show
    /// them.
    private func batteryHealth() -> BatteryHealth? {
        // Looked up once, like `AppleSMC`: the entry is there at boot or
        // never, and the System pane asks every couple of seconds.
        if !batteryServiceProbed {
            batteryServiceProbed = true
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        let service = batteryService
        guard service != 0 else { return nil }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as NSString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // On Apple Silicon the capacities sit in a `BatteryData` dictionary;
        // Intel firmware puts the same keys at the top level.
        let data = property("BatteryData") as? [String: Any] ?? [:]
        func capacity(_ key: String) -> Int? { data[key] as? Int ?? property(key) as? Int }

        var maxCapacityPercent: Int?
        if let design = capacity("DesignCapacity"),
           let fullCharge = capacity("NominalChargeCapacity") ?? capacity("AppleRawMaxCapacity") {
            // Nominal rather than raw: it is the figure System Information
            // reports, and the raw one drifts a few percent between charges.
            maxCapacityPercent = BatteryHealth.maxCapacityPercent(fullCharge: fullCharge, design: design)
        }

        var flagged = false
        var minutesRemaining: Int?
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let source = sources.first,
           let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
            flagged = description[kIOPSBatteryHealthConditionKey] != nil
            // -1 means macOS is still estimating; 0 means nothing to estimate.
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? 0
            minutesRemaining = minutes > 0 ? minutes : nil
        }

        return BatteryHealth(
            maxCapacityPercent: maxCapacityPercent,
            cycleCount: property("CycleCount") as? Int,
            condition: BatteryHealth.condition(flaggedByOS: flagged, maxCapacityPercent: maxCapacityPercent),
            minutesRemaining: minutesRemaining
        )
    }

    // MARK: - SMC (temperature + fans)

    /// Opened at most once, success or failure — same shape as
    /// `hidThermalLoaded` below.
    ///
    /// Only the success was remembered before, so a Mac where the open fails
    /// re-probed `IOServiceGetMatchingService` on every snapshot: about
    /// thirty pointless lookups a minute for as long as the System pane
    /// stayed open. `AppleSMC` is a hardware service that is either there at
    /// boot or never, so there is nothing a later attempt could find.
    private func ensureSMCOpen() {
        guard !smcOpenAttempted else { return }
        smcOpenAttempted = true
        smcOpened = (try? smc.open()) != nil
    }

    /// Every readable sensor, via the HID event system. Empty on machines
    /// that don't publish any there (typically Intel) — `cpuTempCelsius()`
    /// then falls back to SMC on its own.
    private func temperatures() -> [TemperatureReading] {
        if !hidThermalLoaded {
            hidThermalLoaded = true
            hidThermal = HIDThermalReader()
        }
        guard let hidThermal, hidThermal.hasSensors else { return [] }
        return hidThermal.sample()
    }

    /// Prefers the hottest HID CPU/SoC sensor, which is both more accurate
    /// and more widely available than the SMC key probing; falls back to the
    /// original SMC path so Intel Macs keep the reading they always had.
    private func cpuTempCelsius(from readings: [TemperatureReading]) -> Double? {
        if let hottest = readings.hottest(.cpu) { return hottest }
        guard smcOpened else { return nil }
        for key in SMCReader.candidateTempKeys {
            if let value = try? smc.readFloatValue(key: key), value.isFinite, value > 0 {
                return value
            }
        }
        return nil
    }

    private func fanRPMs() -> [Double] {
        guard smcOpened else { return [] }
        let count = smc.fanCount()
        guard count > 0 else { return [] }
        return (0..<count).compactMap { try? smc.readFloatValue(key: SMCReader.fanActualKey(index: $0)) }
    }

    // MARK: - Uptime

    private func uptimeSecs() -> UInt64 {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else { return 0 }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000)
        return UInt64(max(0, Date().timeIntervalSince(bootDate)))
    }
}
