import Foundation

/// A global keyboard shortcut that shows or hides the overlay. Holds the
/// virtual key code and Carbon modifier mask `RegisterEventHotKey` takes,
/// plus the key's printed name, which cannot be derived from the code alone
/// without the keyboard layout that was active when it was recorded.
public struct OverlayHotkey: Equatable, Sendable {
    /// Carbon's modifier bits (`cmdKey`, `shiftKey`, `optionKey`,
    /// `controlKey` in `HIToolbox/Events.h`), repeated here so Core does not
    /// link Carbon.
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    /// ⌃⌥⌘O. `kVK_ANSI_O` is 31.
    public static let suggested = OverlayHotkey(keyCode: 31, modifiers: control | option | command, key: "O")

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A shortcut needs Command, Control or Option: Shift alone plus a
    /// letter would swallow ordinary typing of capitals everywhere.
    public var isUsable: Bool {
        modifiers & (Self.command | Self.control | Self.option) != 0 && !key.isEmpty
    }

    /// Stored as `keyCode:modifiers:key`.
    public var rawValue: String { "\(keyCode):\(modifiers):\(key)" }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods, key: String(parts[2]))
        guard isUsable else { return nil }
    }

    /// In the order macOS menus print modifiers: ⌃⌥⇧⌘.
    public var displayString: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }
}
