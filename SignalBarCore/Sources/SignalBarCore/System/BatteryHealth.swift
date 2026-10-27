import Foundation

/// The figures System Information shows under "Health Information", plus the
/// time estimate `pmset` prints. Read from IOKit by the app; this type only
/// holds the numbers and the two small rules that turn raw ones into them.
public struct BatteryHealth: Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        case normal
        case serviceRecommended
    }

    /// Full-charge capacity as a percentage of the design capacity, capped at
    /// 100 the way macOS caps it — a fresh cell often reads a few percent over.
    public var maxCapacityPercent: Int?
    public var cycleCount: Int?
    public var condition: Condition
    /// Minutes until empty when discharging, until full when charging. `nil`
    /// while macOS is still estimating, or when there is nothing to estimate
    /// (full and on AC).
    public var minutesRemaining: Int?

    public init(maxCapacityPercent: Int?, cycleCount: Int?, condition: Condition, minutesRemaining: Int?) {
        self.maxCapacityPercent = maxCapacityPercent
        self.cycleCount = cycleCount
        self.condition = condition
        self.minutesRemaining = minutesRemaining
    }

    public static func maxCapacityPercent(fullCharge: Int, design: Int) -> Int? {
        guard design > 0, fullCharge >= 0 else { return nil }
        return min(100, Int((Double(fullCharge) / Double(design) * 100).rounded()))
    }

    /// macOS has no public API for its "Service Recommended" verdict. This
    /// says so when the OS attaches a health-condition flag to the power
    /// source, or when the cell has worn past the 80% Apple documents as the
    /// point a battery is considered consumed.
    public static func condition(flaggedByOS: Bool, maxCapacityPercent: Int?) -> Condition {
        if flaggedByOS { return .serviceRecommended }
        if let percent = maxCapacityPercent, percent < 80 { return .serviceRecommended }
        return .normal
    }
}
