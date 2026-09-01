import SwiftUI
import AppKit

/// Minimal AppKit glue for the 3 behaviors SwiftUI Scenes don't expose:
/// hide-not-quit on window close, reopen-on-Dock-click, and toggling the
/// Dock icon (Regular <-> Accessory) — see D1 "App shell" in the plan.
final class PoCAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct DKBMonitorPoCApp: App {
    @NSApplicationDelegateAdaptor(PoCAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)

        // PoC goal: confirm MenuBarExtra coexists cleanly with a regular
        // WindowGroup main window (this is the part flagged as "fairly new
        // API, needs verifying" in the plan before committing the app shell
        // architecture around it).
        MenuBarExtra("DKB PoC", systemImage: "waveform.path.ecg") {
            Button("Show main window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
