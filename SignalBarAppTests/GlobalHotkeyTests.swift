import AppKit
import Carbon.HIToolbox
import Testing
@testable import SignalBarCore
@testable import SignalBar

@MainActor
@Suite struct GlobalHotkeyTests {
    /// ⌃⌥⇧⌘F19: a combination nothing else on a Mac is likely to hold.
    private let unusual = OverlayHotkey(
        keyCode: 80,
        modifiers: OverlayHotkey.control | OverlayHotkey.option | OverlayHotkey.shift | OverlayHotkey.command,
        key: "F19"
    )

    @Test func registersReplacesAndReleasesAShortcut() {
        let hotkey = GlobalHotkey {}
        #expect(hotkey.register(unusual) == noErr)
        // Registering again replaces the first registration instead of
        // colliding with it.
        #expect(hotkey.register(unusual) == noErr)
        #expect(hotkey.register(nil) == noErr)
        // Released: a second owner can now take the same combination.
        let other = GlobalHotkey {}
        #expect(other.register(unusual) == noErr)
        other.unregister()
    }

    @Test func mapsModifierFlagsToCarbonBits() {
        #expect(GlobalHotkey.carbonModifiers([.command, .option]) == OverlayHotkey.command | OverlayHotkey.option)
        #expect(GlobalHotkey.carbonModifiers([.control, .shift]) == OverlayHotkey.control | OverlayHotkey.shift)
        #expect(GlobalHotkey.carbonModifiers([]) == 0)
    }

    @Test func explainsAConflict() {
        #expect(GlobalHotkey.message(for: OSStatus(eventHotKeyExistsErr)).contains("Another app"))
    }
}

/// Uses a throwaway preferences domain, never the real global one.
@Suite(.serialized) struct MetalHUDSettingTests {
    private let setting = MetalHUDSetting(domainName: "com.dangkhoabach.dkb-monitor.tests.metal-hud")

    @Test func switchesOnAndOff() {
        setting.setEnabled(true)
        #expect(setting.isEnabled)
        setting.setEnabled(false)
        #expect(!setting.isEnabled)
    }

    /// A per-host value left behind must not keep the HUD on.
    @Test func switchingOffClearsAPerHostValue() {
        CFPreferencesSetValue("MetalForceHudEnabled" as CFString, kCFBooleanTrue, setting.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        setting.setEnabled(false)
        let perHost = CFPreferencesCopyValue("MetalForceHudEnabled" as CFString, setting.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        #expect(perHost == nil)
    }
}
