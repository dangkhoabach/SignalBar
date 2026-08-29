import DKBMonitorCore
import SwiftUI

/// Color mapping kept in the App target — `DKBMonitorCore` stays UI-agnostic.
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
}
