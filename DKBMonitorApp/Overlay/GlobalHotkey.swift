import AppKit
import Carbon.HIToolbox
import DKBMonitorCore

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`, the one
/// global-shortcut API that needs no Accessibility permission (a global
/// `NSEvent` monitor does, and can only watch, not claim, the keys).
@MainActor
final class GlobalHotkey {
    /// Carbon calls back through a C function with no context pointer of
    /// ours in reach, so live registrations are looked up by their id.
    private static var registrations: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    /// "DKBM", so events for other apps' hot keys are never mistaken for ours.
    private static let signature: OSType = 0x444B_424D

    private let action: () -> Void
    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    /// Replaces whatever this instance had registered. Returns `noErr`, or
    /// Carbon's status — `eventHotKeyExistsErr` when another app already
    /// holds the combination.
    @discardableResult
    func register(_ hotkey: OverlayHotkey?) -> OSStatus {
        unregister()
        guard let hotkey else { return noErr }
        Self.installHandlerIfNeeded()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &newRef
        )
        if status == noErr {
            ref = newRef
            Self.registrations[id] = self
        }
        return status
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.registrations[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            Task { @MainActor in GlobalHotkey.registrations[id]?.action() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// What the Settings page shows when registering failed.
    static func message(for status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? String(localized: "Another app already uses this shortcut.")
            : String(localized: "The shortcut couldn't be registered (error \(Int(status))).")
    }

    /// Carbon modifier mask for a recorded key press.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= OverlayHotkey.command }
        if flags.contains(.shift) { mask |= OverlayHotkey.shift }
        if flags.contains(.option) { mask |= OverlayHotkey.option }
        if flags.contains(.control) { mask |= OverlayHotkey.control }
        return mask
    }

    /// Keys whose typed character is invisible or a private-use code point.
    private static let namedKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// The printed name of a recorded key.
    static func keyName(for event: NSEvent) -> String {
        if let name = namedKeys[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

/// Apple's own Metal Performance HUD — real FPS, frame time and GPU time,
/// drawn by Metal inside each app — switched on for every Metal app through
/// the global `MetalForceHudEnabled` default. Apple documents this in the
/// "Discover the Metal Performance HUD" tech talk: "On macOS, you can set a
/// global value to have the HUD show for all Metal-based applications."
/// Apps pick it up when they next launch.
struct MetalHUDSetting: Sendable {
    private static let key = "MetalForceHudEnabled"
    /// `nil` is the global domain (`defaults -g`) the app uses; tests pass
    /// a throwaway domain.
    let domainName: String?

    static let global = MetalHUDSetting(domainName: nil)

    var domain: CFString { (domainName as CFString?) ?? kCFPreferencesAnyApplication }

    var isEnabled: Bool {
        CFPreferencesCopyValue(Self.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        let key = Self.key as CFString
        CFPreferencesSetValue(key, enabled ? kCFBooleanTrue : nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if !enabled {
            // A per-host value overrides the any-host one; a stale one left
            // from an earlier `defaults -currentHost write` would keep the
            // HUD on after switching it off here.
            CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
