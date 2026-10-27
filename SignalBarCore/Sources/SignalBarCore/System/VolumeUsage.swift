import Foundation

/// One mounted, browsable volume. `SystemStats.diskUsedGB`/`diskTotalGB`
/// only ever describe `/`; this covers external drives and extra internal
/// partitions, which a monitoring app on a machine with an external SSD
/// attached was previously blind to.
public struct VolumeUsage: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let isInternal: Bool

    public init(path: String, name: String, totalBytes: UInt64, freeBytes: UInt64, isInternal: Bool) {
        self.path = path
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isInternal = isInternal
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    public var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }
}
