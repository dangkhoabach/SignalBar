import AppKit

/// Brings the main window forward and restores the Dock icon — the same
/// sequence used by Dock-icon reopen (`AppDelegate`), notification
/// click-through (`NotificationManager`), and the menu bar's "Show DKB
/// Monitor" item (Phase 7). Pulled out once it was about to be written a
/// third time.
@MainActor
enum WindowPresenter {
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
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
