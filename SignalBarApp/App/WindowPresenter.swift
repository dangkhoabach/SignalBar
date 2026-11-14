import AppKit
import SwiftUI

/// Brings the main window forward and restores the Dock icon — the same
/// sequence used by Dock-icon reopen (`AppDelegate`), notification
/// click-through (`NotificationManager`), and the menu bar's "Show
/// SignalBar" item. Pulled out once it was about to be written a
/// third time.
@MainActor
enum WindowPresenter {
    static let mainWindowID = "main"
    /// SwiftUI's own way to open the main window, kept by the status item
    /// (`OpenWindowKeeper`), for when there is no main window to bring forward.
    static var openWindow: OpenWindowAction?

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        // A window SwiftUI never made at launch, or one that was closed for
        // good, is opened anew. Bringing forward only the windows there are
        // left the app with a Dock icon and nothing to show: the menu bar's
        // Show SignalBar and the Dock icon did nothing.
        if mainWindows(in: NSApp.windows).isEmpty {
            openWindow?(id: mainWindowID)
        }
        for window in mainWindows(in: NSApp.windows) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only the `WindowGroup` windows, recognised by the delegate
    /// `WindowAccessor` gives them. `NSApp.windows` also holds the menu bar
    /// panel and the status item windows; ordering the panel front opens it
    /// outside the status item's own tracking, so it never closes.
    static func mainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.delegate is HideInsteadOfCloseDelegate }
    }

    /// Brings the main window forward and selects the Settings sidebar tab —
    /// the single entry point for both the app menu's "Settings…" (Cmd+,,
    /// wired via `CommandGroup(replacing: .appSettings)`) and the menu bar
    /// panel's Settings button, so both land in the same in-window tab
    /// instead of a separate `Settings {}` window.
    static func showSettings() {
        showMainWindow()
        AppNavigationState.shared.sidebarSelection = .settings
    }
}

/// Keeps SwiftUI's `openWindow` for `WindowPresenter`. It sits, with no size,
/// in the status item, which is there from launch whether or not the main
/// window ever is.
struct OpenWindowKeeper: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowPresenter.openWindow = openWindow }
    }
}
