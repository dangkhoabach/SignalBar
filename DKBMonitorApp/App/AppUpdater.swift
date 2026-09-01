import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` — reads
/// `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks` straight from
/// Info.plist (Phase 10), so no manual delegate wiring is needed for the
/// baseline "check on launch + Check for Updates… menu item" behavior.
@MainActor
enum AppUpdater {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func checkForUpdates() {
        shared.checkForUpdates(nil)
    }
}
