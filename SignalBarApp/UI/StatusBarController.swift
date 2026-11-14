import AppKit
import Observation
import SwiftUI

/// The status item and everything hanging off it, as in the author's other
/// menu bar apps: a left click opens the panel, a right click a short menu.
///
/// AppKit rather than SwiftUI's `MenuBarExtra`, which has no right-click
/// menu and doesn't say when it opens or closes.
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    /// When the panel last closed because it lost focus. A click on the icon
    /// while the panel is open takes the focus first and only then reaches
    /// `statusItemClicked`, which would open the panel again at once.
    private var lastClosedAt = Date.distantPast
    /// The content's height when it was measured before the panel was kept.
    private var pendingHeight: CGFloat?

    var isPanelOpen: Bool { panel?.isVisible == true }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityTitle("SignalBar")
        item.button?.addSubview(NSHostingView(rootView: OpenWindowKeeper()))
        statusItem = item
        updateIcon()
    }

    /// The pulse while everything is up; a red warning triangle while a
    /// domain is down (or a Network problem, if asked for), so a problem
    /// shows without opening the panel.
    private func updateIcon() {
        let down = withObservationTracking {
            MenuBarStatusViewModel.shared.showsWarning
        } onChange: {
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        let image: NSImage?
        if down {
            image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "SignalBar")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            image?.isTemplate = false
        } else {
            image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "SignalBar")
            image?.isTemplate = true
        }
        statusItem?.button?.image = image
    }

    // MARK: - Panel

    func togglePanel() {
        isPanelOpen ? closePanel() : openPanel()
    }

    func openPanel() {
        guard !isPanelOpen, Date().timeIntervalSince(lastClosedAt) > 0.3,
              let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        MenuBarStatusViewModel.shared.refresh()
    }

    func closePanel() {
        guard isPanelOpen else { return }
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        lastClosedAt = Date()
    }

    /// The panel as tall as what it shows, growing and shrinking from its
    /// top edge under the menu bar.
    func fitPanel(height: CGFloat) {
        // The content is first measured while `makePanel` builds the panel,
        // before it is kept here; that height is applied once it is.
        guard let panel else { return pendingHeight = height }
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(size: CGSize(width: MenuBarPanelView.width, height: 160), rootView: MenuBarPanelView())
        panel.delegate = self
        panel.onClose = { [weak self] in self?.closePanel() }
        self.panel = panel
        if let pendingHeight {
            fitPanel(height: pendingHeight)
            self.pendingHeight = nil
        }
        return panel
    }

    /// Clicking anywhere else — another app, the desktop, SignalBar's own
    /// window — takes the focus away from the panel.
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showQuickMenu()
        } else {
            togglePanel()
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        func add(_ key: String, _ action: Selector, _ keyEquivalent: String = "") {
            let item = NSMenuItem(title: String(localized: String.LocalizationValue(key), bundle: AppLocale.bundle),
                                  action: action, keyEquivalent: keyEquivalent)
            item.target = self
            menu.addItem(item)
        }
        add("Show SignalBar", #selector(showMainWindow))
        add("Settings…", #selector(showSettings), ",")
        add("Check for Updates…", #selector(checkForUpdates))
        add("About SignalBar", #selector(showAbout))
        menu.addItem(.separator())
        add("Quit SignalBar", #selector(quit), "q")
        // A menu set on the item opens on the next click; it's taken off
        // again so a left click keeps opening the panel.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showMainWindow() { WindowPresenter.showMainWindow() }
    @objc private func showSettings() { WindowPresenter.showSettings() }
    @objc private func checkForUpdates() { AppUpdater.checkForUpdates() }
    @objc private func showAbout() { AboutWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The window under the status item. A non-activating panel: it takes the
/// keyboard without bringing SignalBar forward, so the app the user was in
/// stays the active one, and it shows over full-screen apps.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?

    init<Content: View>(size: CGSize, rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let hosting = NSHostingView(rootView: rootView)
        // The panel keeps a hidden title bar for the system's rounded corners
        // and shadow; SwiftUI would otherwise inset the content by its height.
        hosting.safeAreaRegions = []
        // The panel's height follows the content through
        // `StatusBarController.fitPanel`; sizing itself, the hosting view held
        // the window at its first height, so the panel could grow but never
        // shrink.
        hosting.sizingOptions = []
        contentView = background
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
    }

    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
