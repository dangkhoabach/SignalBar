import Foundation

public enum OverlayCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public enum OverlayLayout: String, CaseIterable, Sendable {
    case vertical, horizontal
}

public enum OverlayScale: String, CaseIterable, Sendable {
    case small, medium, large

    /// Multiplier on the medium font size.
    public var factor: Double {
        switch self {
        case .small: 0.85
        case .medium: 1
        case .large: 1.25
        }
    }
}

public enum OverlayBackground: String, CaseIterable, Sendable {
    case translucent, solid, none
}

/// Which screen the overlay sits on.
public enum OverlayDisplay: Hashable, Sendable {
    case main
    /// The screen under the mouse pointer when the overlay is placed.
    case mouse
    /// A screen by its `NSScreen.localizedName`; falls back to `main` while
    /// that screen is not connected.
    case named(String)

    private static let namePrefix = "name:"

    public var rawValue: String {
        switch self {
        case .main: "main"
        case .mouse: "mouse"
        case .named(let name): Self.namePrefix + name
        }
    }

    public init(rawValue: String) {
        if rawValue == "mouse" {
            self = .mouse
        } else if rawValue.hasPrefix(Self.namePrefix), rawValue.count > Self.namePrefix.count {
            self = .named(String(rawValue.dropFirst(Self.namePrefix.count)))
        } else {
            self = .main
        }
    }
}

/// Everything the Settings page lets the user choose about the overlay.
/// Stored key by key in `app_settings` (see `SettingsRepository`); every
/// value read back goes through the clamps below, so a hand-edited or
/// corrupted row can never produce an overlay that is invisible, off-screen
/// or polling in a tight loop.
public struct OverlayConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var corner: OverlayCorner
    /// Distance in points from the chosen corner's two edges.
    public var offsetX: Int
    public var offsetY: Int
    public var display: OverlayDisplay
    public var layout: OverlayLayout
    public var scale: OverlayScale
    public var opacityPercent: Int
    public var refreshMillis: Int
    /// Rows shown, in order.
    public var metrics: [OverlayMetric]
    public var showOverFullScreen: Bool
    public var sparklines: Bool
    public var background: OverlayBackground
    /// Samples half as often while running on battery.
    public var slowOnBattery: Bool
    /// Global shortcut that shows or hides the overlay; `nil` means none.
    /// Off by default: a system-wide shortcut takes that key combination
    /// away from every other app, so it is only claimed when asked for.
    public var hotkey: OverlayHotkey?

    public static let refreshChoices = [500, 1000, 2000, 5000]
    public static let opacityRange = 30...100
    public static let offsetRange = 0...2000

    public static let defaults = OverlayConfiguration(
        enabled: false,
        corner: .topRight,
        offsetX: 12,
        offsetY: 12,
        display: .main,
        layout: .vertical,
        scale: .medium,
        opacityPercent: 85,
        refreshMillis: 1000,
        metrics: OverlayMetric.defaultMetrics,
        showOverFullScreen: true,
        sparklines: false,
        background: .translucent,
        slowOnBattery: true,
        hotkey: nil
    )

    public init(
        enabled: Bool, corner: OverlayCorner, offsetX: Int, offsetY: Int, display: OverlayDisplay,
        layout: OverlayLayout, scale: OverlayScale, opacityPercent: Int, refreshMillis: Int,
        metrics: [OverlayMetric], showOverFullScreen: Bool, sparklines: Bool, background: OverlayBackground,
        slowOnBattery: Bool, hotkey: OverlayHotkey?
    ) {
        self.enabled = enabled
        self.corner = corner
        self.offsetX = Self.clamp(offsetX, to: Self.offsetRange)
        self.offsetY = Self.clamp(offsetY, to: Self.offsetRange)
        self.display = display
        self.layout = layout
        self.scale = scale
        self.opacityPercent = Self.clamp(opacityPercent, to: Self.opacityRange)
        self.refreshMillis = Self.refreshChoices.contains(refreshMillis) ? refreshMillis : 1000
        self.metrics = metrics
        self.showOverFullScreen = showOverFullScreen
        self.sparklines = sparklines
        self.background = background
        self.slowOnBattery = slowOnBattery
        self.hotkey = hotkey
    }

    /// The sampling interval actually used: doubled on battery when
    /// `slowOnBattery` is on.
    public func effectiveRefreshMillis(onBattery: Bool) -> Int {
        slowOnBattery && onBattery ? refreshMillis * 2 : refreshMillis
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
