import AppKit

/// Brings the main window forward and restores the Dock icon — the same
/// sequence used by Dock-icon reopen (`AppDelegate`), notification
/// click-through (`NotificationManager`), and the menu bar's "Show
/// SignalBar" item. Pulled out once it was about to be written a
/// third time.
@MainActor
enum WindowPresenter {
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        for window in mainWindows(in: NSApp.windows) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only the `WindowGroup` windows, recognised by the delegate
    /// `WindowAccessor` gives them. `NSApp.windows` also holds the menu bar
    /// extra's panel, the status item windows and the overlay panel; ordering
    /// the menu bar panel front opened the dropdown on every Dock-icon reopen,
    /// outside SwiftUI's own open/close tracking, so clicking elsewhere never
    /// closed it.
    static func mainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.delegate is HideInsteadOfCloseDelegate }
    }

    /// Brings the main window forward and selects the Settings sidebar tab —
    /// the single entry point for both the app menu's "Settings…" (Cmd+,,
    /// wired via `CommandGroup(replacing: .appSettings)`) and the menu bar
    /// extra's "Settings…" item, so both land in the same in-window tab
    /// instead of a separate `Settings {}` window.
    static func showSettings() {
        showMainWindow()
        AppNavigationState.shared.sidebarSelection = .settings
    }
}
