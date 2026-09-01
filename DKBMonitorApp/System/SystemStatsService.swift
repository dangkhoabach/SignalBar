import Darwin
import Foundation
import IOKit.ps
import DKBMonitorCore

/// Native replacement for `sysstats.rs`. Where a real public API exists
/// (Mach host stats for CPU/RAM/swap, `statfs` for disk, `getifaddrs` for
/// throughput, `IOPowerSources` for battery) this uses it directly. Where
/// Apple exposes no public API at all — GPU name/utilization, active network
/// interface/Wi-Fi SSID/local IP — this shells out via `Process`, the exact
/// same commands the Rust version used (`system_profiler`/`ioreg`,
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

    private var previousCoreTicks: [[UInt32]]?
    private var previousNetworkBytes: (received: UInt64, transmitted: UInt64)?
    private var previousNetworkPollDate: Date?
    private var gpuNameFetched = false
    private var cachedGPUName: String?

    public init() {}

    public func snapshot() async -> SystemStats {
        ensureSMCOpen()

        let (cpuPercent, cpuCores) = cpuUsage()
        let (ramUsed, ramTotal) = memoryUsageMB()
        let (swapUsed, swapTotal) = swapUsageMB()
        let (diskUsed, diskTotal) = diskUsageGB()
        let network = networkStatus()
        let (downloadKbps, uploadKbps) = networkThroughputKbps()
        let battery = batteryStatus()

        return SystemStats(
            cpuPercent: cpuPercent, cpuCores: cpuCores,
            ramUsedMB: ramUsed, ramTotalMB: ramTotal,
            swapUsedMB: swapUsed, swapTotalMB: swapTotal,
            diskUsedGB: diskUsed, diskTotalGB: diskTotal,
            gpuName: gpuName(), gpuPercent: gpuPercent(),
            networkConnected: network.connected, networkType: network.type, networkName: network.name, networkLocalIP: network.localIP,
            networkDownloadKbps: downloadKbps, networkUploadKbps: uploadKbps,
            cpuTempCelsius: cpuTempCelsius(), batteryPercent: battery.percent, batteryCharging: battery.charging,
            uptimeSecs: uptimeSecs(), fanRPMs: fanRPMs()
        )
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

    private func memoryUsageMB() -> (used: UInt64, total: UInt64) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)

        var totalMemory: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMemory, &totalSize, nil, 0)

        return (used / 1_048_576, totalMemory / 1_048_576)
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
        guard let device = activeInterface() else { return (false, nil, nil, nil) }
        let interfaceType = hardwarePort(for: device)
        let isWiFi = interfaceType?.contains("Wi-Fi") ?? false
        return (true, interfaceType, isWiFi ? wifiSSID(for: device) : nil, localIPAddress(for: device))
    }

    // MARK: - GPU (Process — no public API for name or utilization either)

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
        guard let output = runProcess("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"]) else { return nil }
        let key = "\"Device Utilization %\"="
        guard let range = output.range(of: key) else { return nil }
        let digits = output[range.upperBound...].prefix(while: \.isNumber)
        return Double(digits)
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

    // MARK: - SMC (temperature + fans)

    private func ensureSMCOpen() {
        guard !smcOpened else { return }
        smcOpened = (try? smc.open()) != nil
    }

    private func cpuTempCelsius() -> Double? {
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
