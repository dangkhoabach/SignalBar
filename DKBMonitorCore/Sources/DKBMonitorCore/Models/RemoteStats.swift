import Foundation

public struct RemoteDiskUsage: Sendable, Equatable {
    public let size: String
    public let used: String
    public let available: String
    public let usePercent: String
}

public struct RemoteMemoryUsage: Sendable, Equatable {
    public let totalMB: Int
    public let usedMB: Int
    public let freeMB: Int
    public let availableMB: Int?
}

public struct RemoteUptime: Sendable, Equatable {
    public let raw: String
    public let loadAverages: [Double]
}
