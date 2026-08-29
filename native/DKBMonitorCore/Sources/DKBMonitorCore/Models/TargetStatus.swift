import Foundation

/// Overview row status, in the exact priority order the UI must show it in:
/// Disabled > Paused > Unchecked > Up/Down — same precedence the old web
/// Overview used for its filter chips.
public enum TargetStatus: String, CaseIterable, Hashable, Sendable {
    case up, down, unchecked, paused, disabled

    public init(overview: TargetOverview, now: Date = Date()) {
        if !overview.target.enabled {
            self = .disabled
        } else if overview.target.isPaused(now: now) {
            self = .paused
        } else if let latest = overview.latestCheck {
            self = latest.success ? .up : .down
        } else {
            self = .unchecked
        }
    }

    public var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .unchecked: "Unchecked"
        case .paused: "Paused"
        case .disabled: "Disabled"
        }
    }
}
