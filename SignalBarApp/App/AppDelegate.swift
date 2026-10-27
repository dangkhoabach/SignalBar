import AppKit
import SignalBarCore

/// Minimal AppKit glue for the 3 behaviors SwiftUI Scenes don't expose:
/// keep running after the
/// last window closes, reopen on Dock click, and restore Regular activation
/// policy (Dock icon) when reopening.
/// `@MainActor` because every `NSApplicationDelegate` callback arrives on the
/// main thread anyway, and the database-failure alert below builds an
/// `NSAlert` — AppKit UI that must never be touched from anywhere else.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Layout-snapshot mode renders the panes to PNG and exits, so it
        // must short-circuit before the scheduler, Sparkle and the wake
        // observer start doing real work.
        if let directory = LayoutSnapshot.requestedDirectory {
            Task { await LayoutSnapshot.run(directory: directory) }
            return
        }

        // Before anything else takes a dependency on it: without the
        // database there is no monitoring, no settings and no history, and
        // every one of those failures is silent on its own.
        if let failure = AppDatabase.openFailure {
            presentDatabaseFailure(failure)
        }

        MenuBarStatsViewModel.shared.start()
        OverlayWindowController.shared.start()
        NotificationManager.shared.onRouteSelected = { route in
            AppNavigationState.shared.handleNotificationRoute(route)
        }
        Task { await AppScheduler.shared?.start() }
        _ = AppUpdater.shared // starts Sparkle's check-on-launch loop

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

    /// Says plainly that the app can't do its job, and where the file it
    /// couldn't open lives, so the user has somewhere to start.
    ///
    /// A blocking alert rather than a banner: an uptime monitor that isn't
    /// monitoring looks exactly like one where everything is fine, and that
    /// is the single most misleading state this app can be in.
    private func presentDatabaseFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SignalBar can't open its database"
        alert.informativeText = """
            Nothing will be monitored and no settings can be saved until this is fixed.

            \(error.localizedDescription)

            The database is at:
            \(AppDatabaseLocation.productionPath().path)
            """
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AppDatabaseLocation.productionPath()])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Settings writes are debounced by half a second, and quitting
        // cancels the task that was waiting. Without this, changing a setting
        // and immediately pressing Cmd+Q discarded the change silently.
        SettingsViewModel.shared.flushPendingSave()
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
