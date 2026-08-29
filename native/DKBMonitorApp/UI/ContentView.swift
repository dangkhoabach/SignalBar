import SwiftUI
import DKBMonitorCore

/// Placeholder — Overview/Sidebar land in Phase 11.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("DKB Monitor Native")
                .font(.title2)
            Text("Core package: \(DKBMonitorCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 480, height: 320)
    }
}
