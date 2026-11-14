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

@MainActor
@Suite struct WindowPresenterReopenTests {
    /// With no main window at all (SwiftUI made none at launch, or it was
    /// closed for good), Show SignalBar and the Dock icon open a new one
    /// rather than bringing forward nothing.
    @Test func showMainWindowOpensOneWhenThereIsNone() async throws {
        // Closed for good: without its delegate the close isn't turned into a hide.
        let closed = WindowPresenter.mainWindows(in: NSApp.windows)
        let delegate = closed.first?.delegate
        for window in closed {
            window.delegate = nil
            window.close()
        }
        defer {
            // SwiftUI may bring back the same window; it gets its delegate again.
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(WindowPresenter.mainWindowID) == true && window.delegate == nil {
                window.delegate = delegate
            }
        }
        #expect(WindowPresenter.mainWindows(in: NSApp.windows).isEmpty)
        #expect(WindowPresenter.openWindow != nil)

        WindowPresenter.showMainWindow()
        func shown() -> Bool {
            NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(WindowPresenter.mainWindowID) == true }
        }
        for _ in 0..<40 where !shown() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shown())
    }
}
