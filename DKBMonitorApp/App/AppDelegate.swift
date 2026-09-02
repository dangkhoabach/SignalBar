import AppKit

/// Minimal AppKit glue for the 3 behaviors SwiftUI Scenes don't expose
/// (see D2/Mục 2 in docs/swift-native-port-plan.md): keep running after the
/// last window closes, reopen on Dock click, and restore Regular activation
/// policy (Dock icon) when reopening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarStatsViewModel.shared.start()
        NotificationManager.shared.onRouteSelected = { route in
            AppNavigationState.shared.handleNotificationRoute(route)
        }
        Task { await AppScheduler.shared?.start() }
        _ = AppUpdater.shared // starts Sparkle's check-on-launch loop (Phase 10)

        // Scheduler.tick's own loop just sleeps a fixed interval between
        // runs, so a sleep/wake cycle leaves it waiting out the rest of that
        // interval before the next check - this forces an immediate
        // catch-up tick the moment the Mac wakes, instead of waiting up to
        // `Scheduler.tickIntervalSecs` more. Core has no AppKit dependency,
        // so it can't observe this notification itself (see Scheduler.tick's
        // doc comment).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await AppScheduler.shared?.tick() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WindowPresenter.showMainWindow()
        // Reopen is already fully handled above (existing window is unhidden and
        // brought to front) - returning true here would also let AppKit run its
        // own default reopen handling, which for a SwiftUI WindowGroup means
        // instantiating a brand-new window since hasVisibleWindows is false
        // (the window was only orderOut'd, not closed). That produced a
        // duplicate window on every Dock-icon reopen.
        return false
    }
}
