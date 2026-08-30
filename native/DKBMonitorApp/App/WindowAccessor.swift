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

/// SwiftUI's `WindowGroup` has no direct API to intercept close behavior or
/// hide the title text — this reaches into AppKit once via
/// `NSViewRepresentable` to grab the window and configure both. Ported from
/// DKB-Downloader's `WindowAccessor` (`native/DKBDownloaderApp/App/
/// WindowAccessor.swift`), which already solved the "DKB Monitor" title bar
/// text the user didn't want — `titleVisibility = .hidden` alone leaves an
/// empty gray strip above the toolbar, so it's paired with
/// `titlebarAppearsTransparent` and `.fullSizeContentView` (same as
/// Downloader) to let the toolbar sit flush at the very top instead.
struct WindowAccessor: NSViewRepresentable {
    let delegate: HideInsteadOfCloseDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.delegate = delegate
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
