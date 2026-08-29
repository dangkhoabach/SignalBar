import SwiftUI
import DKBMonitorCore

@main
struct DKBMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let windowDelegate = HideInsteadOfCloseDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
        }

        Settings {
            Text("Settings — Phase 12")
                .padding()
                .frame(width: 400, height: 200)
        }

        // `waveform.path.ecg`: an SF Symbol standing in for the plan's
        // suggested PDF vector Asset Catalog glyph (see Mục 2) — no
        // Figma/Sketch export exists to trace one from, and this symbol is
        // already the same "activity pulse" concept as the Rust version's
        // hand-drawn glyph, while being vector, crisp at any size, and
        // auto-template-tinted for light/dark menu bars with zero
        // asset-pipeline maintenance.
        MenuBarExtra("DKB Monitor", systemImage: "waveform.path.ecg") {
            MenuBarContentView()
        }
    }
}
