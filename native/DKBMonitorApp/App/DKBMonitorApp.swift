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
        .commands {
            // Replaces the default "Settings…" menu item (still Cmd+,) so it
            // opens the Settings sidebar tab in the main window instead of a
            // separate `Settings {}` scene — same destination as the menu
            // bar extra's "Settings…" item below.
            CommandGroup(replacing: .appSettings) {
                // Deferred to the next run loop tick: firing straight from
                // the menu item's action handler mutates
                // `AppNavigationState.sidebarSelection` while AppKit's menu
                // is still in its own tracking run loop mode, which left the
                // sidebar `List`'s selection/click handling stuck — the
                // symptom was the whole sidebar becoming unresponsive right
                // after using Settings… from the app menu (Cmd+,), but not
                // from the menu bar extra (that menu closes via a different
                // path that doesn't hit this).
                Button("Settings…") {
                    DispatchQueue.main.async { WindowPresenter.showSettings() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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
