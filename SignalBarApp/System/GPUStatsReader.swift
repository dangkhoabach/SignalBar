import Foundation
import IOKit

/// GPU load and memory from the `IOAccelerator` registry entry's
/// `PerformanceStatistics` — the same dictionary `ioreg -c IOAccelerator`
/// prints, read in-process instead of forking `ioreg` for it. Measured at
/// 0.035 ms a read on an M3 Pro, which is what makes a once-a-second overlay
/// affordable.
///
/// Same shape as the `AppleSmartBattery` lookup in `SystemStatsService`: the
/// entry is found once and kept.
final class GPUStatsReader {
    struct Stats: Equatable {
        var utilizationPercent: Double?
        var inUseMemoryBytes: UInt64?
    }

    private static let utilizationKey = "Device Utilization %"
    private static let inUseMemoryKey = "In use system memory"

    private var service: io_service_t = 0
    private var probed = false

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// `nil` on a Mac whose accelerator publishes no statistics.
    func read() -> Stats? {
        if !probed {
            probed = true
            service = Self.findAccelerator()
        }
        guard service != 0 else { return nil }
        guard let statistics = Self.statistics(of: service) else {
            // The entry went away (a GPU driver restart). Look it up again
            // next time rather than reading a dead handle forever.
            IOObjectRelease(service)
            service = 0
            probed = false
            return nil
        }
        return Self.parse(statistics)
    }

    /// Split out so the key handling can be tested without real hardware.
    static func parse(_ statistics: [String: Any]) -> Stats {
        Stats(
            utilizationPercent: (statistics[utilizationKey] as? NSNumber)?.doubleValue,
            inUseMemoryBytes: (statistics[inUseMemoryKey] as? NSNumber)?.uint64Value
        )
    }

    private static func statistics(of service: io_service_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    /// The first accelerator that reports a utilization figure. A Mac with
    /// two GPUs (Intel + AMD) is not told apart; Apple Silicon has one.
    private static func findAccelerator() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var candidate = IOIteratorNext(iterator)
        while candidate != 0 {
            if statistics(of: candidate)?[utilizationKey] != nil {
                return candidate
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(iterator)
        }
        return 0
    }
}
