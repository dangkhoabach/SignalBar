import Foundation

/// How this Mac's logical CPUs are grouped into performance levels — Apple
/// Silicon reports an Efficiency and a Performance cluster, Intel reports a
/// single unnamed one. Without this, a row of 8-24 identical per-core bars
/// says nothing about *which* cores are busy.
///
/// The sysctl reads that populate it (`hw.nperflevels`,
/// `hw.perflevelN.name/logicalcpu`) live in the app target; the index→cluster
/// mapping lives here because it's pure arithmetic worth testing against
/// machine shapes this developer's Mac doesn't have.
public struct CPUTopology: Sendable, Equatable {
    public struct Level: Sendable, Equatable, Identifiable {
        public var id: Int { index }
        /// Performance level as macOS numbers them: 0 is the *fastest*.
        public let index: Int
        public let name: String
        public let coreCount: Int

        public init(index: Int, name: String, coreCount: Int) {
            self.index = index
            self.name = name
            self.coreCount = coreCount
        }

        /// Short prefix for core labels — "P1", "E3".
        public var symbol: String { String(name.prefix(1)).uppercased() }
    }

    public let levels: [Level]

    public init(levels: [Level]) {
        self.levels = levels
    }

    /// Fallback for a machine that reports no usable performance levels.
    public static func flat(coreCount: Int) -> CPUTopology {
        CPUTopology(levels: [Level(index: 0, name: "Cores", coreCount: coreCount)])
    }

    public var hasClusters: Bool { levels.count > 1 }

    /// Logical CPU index → its level, built slowest level first.
    ///
    /// macOS numbers logical CPUs starting with the *slowest* performance
    /// level (CPU 0 is an E-core on Apple Silicon), which is the opposite of
    /// the order `hw.perflevelN` uses — hence the `index > index` sort.
    private var assignment: [(level: Level, position: Int)] {
        levels.sorted { $0.index > $1.index }.flatMap { level in
            (0..<level.coreCount).map { (level, $0) }
        }
    }

    /// Per-core display labels, one per logical CPU, in `cpuCores` order.
    /// A single-level (Intel) machine gets bare numbers — there is no
    /// cluster to disambiguate, so a "C1"-style prefix would only add noise.
    public func coreLabels() -> [String] {
        guard hasClusters else {
            return (0..<(levels.first?.coreCount ?? 0)).map { "\($0 + 1)" }
        }
        return assignment.map { "\($0.level.symbol)\($0.position + 1)" }
    }

    /// Level each logical CPU belongs to, one per core, in `cpuCores` order.
    public func coreLevels() -> [Level] {
        assignment.map(\.level)
    }

    /// One line describing the machine, e.g. "4 Efficiency · 4 Performance".
    public var summary: String {
        guard hasClusters else { return "\(levels.first?.coreCount ?? 0) cores" }
        return levels.sorted { $0.index > $1.index }
            .map { "\($0.coreCount) \($0.name)" }
            .joined(separator: " · ")
    }
}
