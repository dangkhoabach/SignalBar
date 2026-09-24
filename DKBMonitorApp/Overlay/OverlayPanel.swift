import AppKit

/// The borderless window the performance overlay is drawn in.
///
/// Everything here is about staying out of the way: it never takes focus
/// (a game or editor keeps its keyboard), clicks go through it, it is left
/// out of Cmd+Tab, Mission Control and the Window menu, and it has no shadow
/// or animation to recomposite.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        // Closing the main window hides the whole app (`NSApp.hide`, see
        // `HideInsteadOfCloseDelegate`); without this the overlay would
        // vanish with it.
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        // The menu bar's level: above every normal and floating window.
        level = .statusBar
    }

    /// `.fullScreenAuxiliary` is what lets a window share another app's
    /// full-screen Space; without it the overlay stays on the desktop Spaces.
    func setShowsOverFullScreen(_ show: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if show { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }

    /// Called when a drag the user started on the unlocked panel ends.
    var onDragEnded: (() -> Void)?

    /// While unlocked the panel takes clicks, and any press drags it.
    /// `performDrag` runs the move loop itself and returns on mouse-up,
    /// which is what makes "drag ended" a single, exact moment here.
    override func sendEvent(_ event: NSEvent) {
        if !ignoresMouseEvents, event.type == .leftMouseDown {
            performDrag(with: event)
            onDragEnded?()
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
