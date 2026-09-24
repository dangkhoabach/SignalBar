import AppKit
import DKBMonitorCore
import Observation
import SwiftUI

/// Shows, hides and places the overlay panel from the saved configuration.
///
/// The configuration lives in `SettingsViewModel.settings.overlay` like every
/// other setting; this observes it, so the Settings page and the menu bar
/// toggle only ever edit the setting and never talk to the window.
@MainActor
final class OverlayWindowController {
    static let shared = OverlayWindowController()

    let model: OverlayViewModel

    private let settings: SettingsViewModel
    private(set) var panel: OverlayPanel?
    private var hostingView: NSHostingView<OverlayView>?
    private var configuration = OverlayConfiguration.defaults
    private var contentSize = CGSize.zero
    private var screenIndex: Int?
    private var started = false

    /// Why sampling is suspended right now. The overlay stays ordered in
    /// while paused (nothing is visible anyway); only the loop stops, so a
    /// locked Mac or a sleeping display costs no wake-ups at all.
    enum PauseReason: Hashable {
        case displaysAsleep, sessionInactive, systemAsleep
    }
    private(set) var pauseReasons = Set<PauseReason>()
    private lazy var hotkey = GlobalHotkey { [weak self] in
        self?.settings.settings.overlay.enabled.toggle()
    }
    private var registeredHotkey: OverlayHotkey?
    private var hotkeyApplied = false
    private var onBattery = false

    /// Injectable so tests can drive it from an in-memory database.
    init(settings: SettingsViewModel = .shared, sampler: OverlaySampling = SystemStatsService()) {
        self.settings = settings
        self.model = OverlayViewModel(sampler: sampler)
    }

    func start() {
        guard !started else { return }
        started = true
        settings.loadIfNeeded()
        model.onSample = { [weak self] in
            self?.followPointerIfNeeded()
            self?.followPowerSource()
        }
        observePauseEvents()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        observeSettings()
        apply(settings.settings.overlay)
    }

    /// `withObservationTracking` fires once per registration and before the
    /// new value is stored, hence the hop to the next main-actor turn and the
    /// re-registration there.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings.overlay
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.settings.settings.overlay)
                self.observeSettings()
            }
        }
    }

    private func apply(_ new: OverlayConfiguration) {
        let changed = new != configuration
        configuration = new
        // Before the enabled check: the shortcut is how a hidden overlay
        // gets shown again.
        applyHotkey(new.hotkey)
        guard new.enabled, !new.metrics.isEmpty else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        if changed {
            hostingView?.rootView = makeView()
        }
        model.recordsHistory = new.sparklines
        model.metrics = Set(new.metrics)
        panel.setShowsOverFullScreen(new.showOverFullScreen)
        panel.alphaValue = CGFloat(new.opacityPercent) / 100
        updateSampling()
        reposition()
        panel.orderFrontRegardless()
    }

    private func applyHotkey(_ wanted: OverlayHotkey?) {
        guard !hotkeyApplied || wanted != registeredHotkey else { return }
        hotkeyApplied = true
        registeredHotkey = wanted
        let status = hotkey.register(wanted)
        model.hotkeyError = status == noErr ? nil : GlobalHotkey.message(for: status)
    }

    private func hide() {
        setUnlocked(false)
        panel?.orderOut(nil)
        updateSampling()
    }

    /// Runs the loop only while the overlay is shown and nothing pauses it,
    /// at the interval the power source calls for. Starting a loop that is
    /// already running at that interval is a no-op in the model.
    private func updateSampling() {
        let shown = configuration.enabled && !configuration.metrics.isEmpty
        if shown, pauseReasons.isEmpty {
            model.start(intervalMillis: configuration.effectiveRefreshMillis(onBattery: onBattery))
        } else {
            model.stop()
        }
    }

    func setPaused(_ paused: Bool, for reason: PauseReason) {
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        updateSampling()
    }

    private func observePauseEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, PauseReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
            (NSWorkspace.willSleepNotification, .systemAsleep, true),
            (NSWorkspace.didWakeNotification, .systemAsleep, false),
        ]
        for (name, reason, paused) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(paused, for: reason) }
            }
        }
    }

    /// Switches between the normal and the on-battery interval when the
    /// power source changes, read from the sample the overlay already takes.
    private func followPowerSource() {
        let nowOnBattery = model.sample.batteryCharging == false
        guard nowOnBattery != onBattery else { return }
        onBattery = nowOnBattery
        updateSampling()
    }

    /// "Unlock to move": the panel takes the mouse so it can be dragged,
    /// and each drop is saved as the nearest corner plus offsets. Not
    /// persisted — a relaunch always comes back locked and click-through.
    func setUnlocked(_ unlocked: Bool) {
        guard model.isUnlocked != unlocked else { return }
        model.isUnlocked = unlocked
        panel?.ignoresMouseEvents = !unlocked
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        panel.onDragEnded = { [weak self] in self?.saveDraggedPosition() }
        let hosting = NSHostingView(rootView: makeView())
        // The SwiftUI view sizes itself (`fixedSize`) and the panel follows
        // it through `contentSizeChanged`, never the other way round. As the
        // window's content view a hosting view still resized the window to
        // its own fractional size a moment later, knocking the panel a point
        // off its corner; inside a plain container it can't.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(hosting)
        panel.contentView = container
        hosting.frame = container.bounds
        self.panel = panel
        hostingView = hosting
        return panel
    }

    private func makeView() -> OverlayView {
        OverlayView(model: model, configuration: configuration) { [weak self] size in
            self?.contentSizeChanged(size)
        }
    }

    /// Rounded up to whole points: SwiftUI reports fractional sizes, and
    /// AppKit rounds a window frame on its own, which left the panel a point
    /// away from the edge it is anchored to.
    private func contentSizeChanged(_ rawSize: CGSize) {
        let size = CGSize(width: rawSize.width.rounded(.up), height: rawSize.height.rounded(.up))
        guard size != contentSize else { return }
        contentSize = size
        reposition()
    }

    private func reposition() {
        guard let panel, configuration.enabled else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let index = OverlayPlacement.screenIndex(
            for: configuration.display,
            names: screens.map(\.localizedName),
            frames: screens.map(\.frame),
            mouse: NSEvent.mouseLocation
        )
        screenIndex = index
        let screen = screens[index]
        let hz = screen.maximumFramesPerSecond
        if model.displayHz != hz { model.displayHz = hz > 0 ? hz : nil }
        let frame = OverlayPlacement.frame(
            size: contentSize, corner: configuration.corner,
            offsetX: configuration.offsetX, offsetY: configuration.offsetY,
            in: screen.visibleFrame
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Turns where the panel was dropped into the saved corner and offsets,
    /// and pins the screen it was dropped on. Saving goes through the
    /// settings like any other edit, which then re-places the panel exactly
    /// where it already is.
    private func saveDraggedPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.screens.first else { return }
        let anchor = OverlayPlacement.anchor(of: panel.frame, in: screen.visibleFrame)
        var overlay = settings.settings.overlay
        overlay.corner = anchor.corner
        overlay.offsetX = min(anchor.offsetX, OverlayConfiguration.offsetRange.upperBound)
        overlay.offsetY = min(anchor.offsetY, OverlayConfiguration.offsetRange.upperBound)
        let screens = NSScreen.screens
        if let index = screenIndex, screens.indices.contains(index), screens[index] != screen {
            overlay.display = .named(screen.localizedName)
        }
        settings.settings.overlay = overlay
    }

    /// With "Display with the pointer", moves the overlay once the pointer
    /// has crossed onto another screen; checked once per sample.
    private func followPointerIfNeeded() {
        guard configuration.display == .mouse else { return }
        let screens = NSScreen.screens
        let index = OverlayPlacement.screenIndex(
            for: .mouse, names: [], frames: screens.map(\.frame), mouse: NSEvent.mouseLocation
        )
        if index != screenIndex { reposition() }
    }
}
