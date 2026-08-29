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
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
