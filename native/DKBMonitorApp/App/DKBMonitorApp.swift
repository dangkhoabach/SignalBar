import SwiftUI
import DKBMonitorCore

@main
struct DKBMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("themePreference") private var themePreferenceRaw = ThemePreference.system.rawValue
    private let windowDelegate = HideInsteadOfCloseDelegate()

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
                .preferredColorScheme(themePreference.colorScheme)
        }

        Settings {
            SettingsView()
                .preferredColorScheme(themePreference.colorScheme)
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
