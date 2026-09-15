import Darwin
import DKBMonitorCore
import Foundation

/// Per-process CPU/memory via `libproc` — the same mechanism `top`/Activity
/// Monitor use, and no different in kind from `SystemStatsService`'s own
/// Mach/IOKit calls for whole-machine stats. Returns every OS process;
/// `SystemViewModel` matches these against `NSRunningApplication` to show
/// user-facing *apps* (Task-Manager-style) rather than a raw process list.
///
/// CPU% is computed the same delta-over-elapsed-wall-time way
/// `SystemStatsService.cpuUsage()` does for the whole machine (see that
/// file), just keyed per-pid instead of per-core, and normalized by core
/// count so it reads as a 0-100 share of the machine rather than being able
/// to exceed 100% for a multi-threaded process (`top`'s convention, but not
/// what "looks like Windows Task Manager" expects).
public actor ProcessListService: ProcessListProvider {
    private var previousCPUTimes: [pid_t: UInt64] = [:]
    private var previousSampleDate: Date?

    public init() {}

    public func processUsages() async -> [ProcessUsage] {
        let now = Date()
        let elapsedSinceLastSample = previousSampleDate.map { max(now.timeIntervalSince($0), 0.1) }
        let coreCount = max(ProcessInfo.processInfo.activeProcessorCount, 1)

        var currentCPUTimes: [pid_t: UInt64] = [:]
        var usages: [ProcessUsage] = []

        for pid in runningPIDs() {
            guard let info = taskInfo(for: pid) else { continue }
            let totalCPUNanos = info.pti_total_user + info.pti_total_system
            currentCPUTimes[pid] = totalCPUNanos

            var cpuPercent = 0.0
            if let elapsed = elapsedSinceLastSample,
               let previous = previousCPUTimes[pid], totalCPUNanos >= previous {
                let deltaSeconds = Double(totalCPUNanos - previous) / 1_000_000_000
                cpuPercent = (deltaSeconds / elapsed / Double(coreCount)) * 100
            }

            usages.append(ProcessUsage(
                pid: pid,
                name: processName(for: pid) ?? "pid \(pid)",
                cpuPercent: cpuPercent,
                memoryMB: Double(info.pti_resident_size) / 1_048_576
            ))
        }

        previousCPUTimes = currentCPUTimes
        previousSampleDate = now
        return usages
    }

    private func runningPIDs() -> [pid_t] {
        let neededSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard neededSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(neededSize) / MemoryLayout<pid_t>.stride)
        let writtenSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, neededSize)
        guard writtenSize > 0 else { return [] }
        return Array(pids.prefix(Int(writtenSize) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }
    }

    /// Reads into raw allocated memory rather than a Swift `proc_taskinfo()`
    /// value — the imported C struct has no synthesized zero-argument
    /// initializer, so this sidesteps that instead of hand-rolling a
    /// memberwise one (same reasoning as `SystemStatsService`'s hand-mirrored
    /// `XSWUsage`, just via raw memory instead of a mirror struct since this
    /// one already exists as a proper importable C type).
    private func taskInfo(for pid: pid_t) -> proc_taskinfo? {
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<proc_taskinfo>.alignment)
        defer { buffer.deallocate() }
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, buffer, size) == size else { return nil }
        return buffer.load(as: proc_taskinfo.self)
    }

    private func processName(for pid: pid_t) -> String? {
        // `MAXCOMLEN * 2 + 1` is what `proc_name` itself writes at most; the
        // old 64-byte buffer could cut a long name mid-UTF-8 and turn the
        // remainder into replacement characters.
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
