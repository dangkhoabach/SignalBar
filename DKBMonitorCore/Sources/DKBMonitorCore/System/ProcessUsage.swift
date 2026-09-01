import Foundation

/// One row of a Task-Manager-style process list for the System pane.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Relative to one CPU core (matches `top`/Activity Monitor), normalized
    /// so the sum across all processes is comparable to the machine's
    /// overall `SystemStats.cpuPercent`.
    public var cpuPercent: Double
    public var memoryMB: Double

    public init(pid: Int32, name: String, cpuPercent: Double, memoryMB: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
    }
}

/// Implemented by the app target using `libproc` — cannot live in this
/// package, which deliberately links no system frameworks beyond
/// Foundation/Security (see D6 in the port plan).
public protocol ProcessListProvider: Sendable {
    /// Every process currently readable via `libproc`, unsorted and
    /// untruncated — matching raw OS processes to user-facing apps (and
    /// picking the top N of those) needs `NSRunningApplication`, which is
    /// AppKit and so belongs in the App target's view model, not here.
    func processUsages() async -> [ProcessUsage]
}
