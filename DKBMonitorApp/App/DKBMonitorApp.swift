import SwiftUI
import DKBMonitorCore

@main
struct DKBMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("themePreference") private var themePreferenceRaw = ThemePreference.system.rawValue
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    private let windowDelegate = HideInsteadOfCloseDelegate()

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRaw) ?? .system
    }

    private var appLocale: AppLocale {
        AppLocale(rawValue: languageRaw) ?? .systemDefault
    }

    // `.preferredColorScheme(nil)` is meant to hand control back to the OS,
    // but on an already-visible NSWindow that previously had an explicit
    // scheme applied, SwiftUI doesn't reliably clear the appearance it set
    // under the hood - switching Dark/Light -> System silently no-ops.
    // Driving `NSApp.appearance` directly (nil = follow the system) doesn't
    // have that staleness problem.
    private func applyAppearance() {
        switch themePreference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
                .preferredColorScheme(themePreference.colorScheme)
                .environment(\.locale, appLocale.locale)
                .onAppear { applyAppearance() }
                .onChange(of: themePreferenceRaw) { _, _ in applyAppearance() }
        }
        .commands {
            // Standard Sparkle placement: right under "About DKB Monitor" in
            // the app menu — matches DKB Downloader's app menu (and this
            // app's own menu bar extra, see MenuBarContentView).
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdater.checkForUpdates()
                }
            }

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
                .environment(\.locale, appLocale.locale)
        }
    }
}
