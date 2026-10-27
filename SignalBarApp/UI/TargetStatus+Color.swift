import SignalBarCore
import SwiftUI

/// Color/label presentation kept in the App target — `SignalBarCore` stays
/// UI-agnostic and has no String Catalog of its own.
extension TargetStatus {
    var color: Color {
        switch self {
        case .up: .green
        case .down: .red
        case .unchecked: .gray
        case .paused: .orange
        case .disabled: .secondary
        }
    }

    /// `Core`'s `label` is a plain `String` (no localization dependency);
    /// this mirrors it as a `LocalizedStringKey` literal per case so
    /// Xcode's String Catalog extraction picks it up.
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .unchecked: "Unchecked"
        case .paused: "Paused"
        case .disabled: "Disabled"
        }
    }
}
