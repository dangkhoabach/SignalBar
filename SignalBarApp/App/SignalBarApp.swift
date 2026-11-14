import SwiftUI
import SignalBarCore

@main
struct SignalBarApp: App {
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
        WindowGroup(id: WindowPresenter.mainWindowID) {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
                .preferredColorScheme(themePreference.colorScheme)
                .environment(\.locale, appLocale.locale)
                .onAppear { applyAppearance() }
                .onChange(of: themePreferenceRaw) { _, _ in applyAppearance() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SignalBar") { AboutWindow.show() }
            }
            // Standard Sparkle placement: right under "About SignalBar" in
            // the app menu, as in the menu bar panel's footer.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdater.checkForUpdates()
                }
            }

            // Replaces the default "Settings…" menu item (still Cmd+,) so it
            // opens the Settings sidebar tab in the main window instead of a
            // separate `Settings {}` scene — same destination as the menu
            // bar panel's Settings button.
            CommandGroup(replacing: .appSettings) {
                // Deferred to the next run loop tick: firing straight from
                // the menu item's action handler mutates
                // `AppNavigationState.sidebarSelection` while AppKit's menu
                // is still in its own tracking run loop mode, which left the
                // sidebar `List`'s selection/click handling stuck — the
                // symptom was the whole sidebar becoming unresponsive right
                // after using Settings… from the app menu (Cmd+,), but not
                // from the menu bar panel (that closes via a different path
                // that doesn't hit this).
                Button("Settings…") {
                    DispatchQueue.main.async { WindowPresenter.showSettings() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // One main window: no File › New Window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
