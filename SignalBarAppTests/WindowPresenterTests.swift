import AppKit
import Testing
@testable import SignalBar

@MainActor
@Suite struct WindowPresenterTests {
    /// The menu bar extra's panel lives in `NSApp.windows` beside the main
    /// window; only the main window may be brought forward, or the dropdown
    /// opens on its own.
    @Test func picksOnlyWindowsWithTheHideInsteadOfCloseDelegate() {
        let delegate = HideInsteadOfCloseDelegate()
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        main.delegate = delegate
        let menuBarPanel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)

        let picked = WindowPresenter.mainWindows(in: [menuBarPanel, main])

        #expect(picked.count == 1)
        #expect(picked.first === main)
    }

    /// Opening the menu bar extra unhides the app, which puts back every
    /// window the hide took away; the closed main window must not be one.
    @Test func aClosedWindowStaysClosedWhenTheAppUnhides() {
        let delegate = HideInsteadOfCloseDelegate()
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.delegate = delegate
        main.orderFront(nil)
        defer {
            main.orderOut(nil)
            NSApp.setActivationPolicy(.regular)
        }

        #expect(delegate.windowShouldClose(main) == false)
        NSApp.unhide(nil)

        #expect(!main.isVisible)
    }
}
