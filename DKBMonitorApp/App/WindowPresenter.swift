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
        // The overlay panel is one of `NSApp.windows` too, and must stay
        // exactly as its setting says rather than be brought forward here.
        for window in NSApp.windows where !(window is OverlayPanel) {
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
