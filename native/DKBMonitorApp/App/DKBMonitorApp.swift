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

        // `waveform.path.ecg`: official SF Symbol, same "activity pulse"
        // concept as the Rust version's hand-drawn tray glyph — chosen over
        // a custom-traced PDF vector for best-in-class Apple platform
        // integration (crisp at any size/weight, auto-template-tinted for
        // light/dark menu bars, tracks future SF Symbols refinements).
        MenuBarExtra("DKB Monitor", systemImage: "waveform.path.ecg") {
            MenuBarContentView()
        }
    }
}
