import AppKit
import Testing
@testable import DKB_Monitor

@MainActor
@Suite struct WindowPresenterTests {
    /// The menu bar extra's panel and the overlay panel live in
    /// `NSApp.windows` beside the main window; only the main window may be
    /// brought forward, or the dropdown opens on its own.
    @Test func picksOnlyWindowsWithTheHideInsteadOfCloseDelegate() {
        let delegate = HideInsteadOfCloseDelegate()
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        main.delegate = delegate
        let menuBarPanel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let overlay = OverlayPanel()

        let picked = WindowPresenter.mainWindows(in: [menuBarPanel, main, overlay])

        #expect(picked.count == 1)
        #expect(picked.first === main)
    }
}
