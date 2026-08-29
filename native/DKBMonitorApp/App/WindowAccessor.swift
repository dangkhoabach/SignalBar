import AppKit
import SwiftUI

/// Intercepts the red close button to hide the window instead of destroying
/// it, and switches the Dock icon to Accessory — matches the Tauri version's
/// `WindowEvent::CloseRequested` handling (`window.hide()` + `prevent_close()`
/// + `ActivationPolicy::Accessory`) so the app keeps monitoring in the
/// background instead of quitting.
final class HideInsteadOfCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

/// SwiftUI's `WindowGroup` has no direct API to intercept close behavior —
/// this reaches into AppKit once via `NSViewRepresentable` to grab the
/// window and attach the delegate above.
struct WindowAccessor: NSViewRepresentable {
    let delegate: HideInsteadOfCloseDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = delegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
