import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` — reads
/// `SUFeedURL`/`SUPublicEDKey` straight from Info.plist, so no
/// manual delegate wiring is needed for the baseline "check on launch +
/// Check for Updates… menu item" behavior.
///
/// Whether it checks on its own is the user's answer, not a build setting:
/// Info.plist no longer pins `SUEnableAutomaticChecks`, so Sparkle asks on
/// first launch and stores the reply, and `automaticallyChecksForUpdates`
/// below is the same stored value that Settings › Updates reads and writes.
@MainActor
enum AppUpdater {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Round-trips Sparkle's own preference rather than shadowing it in
    /// `@AppStorage` — a second copy would drift from the answer Sparkle
    /// actually acts on.
    static var automaticallyChecksForUpdates: Bool {
        get { shared.updater.automaticallyChecksForUpdates }
        set { shared.updater.automaticallyChecksForUpdates = newValue }
    }

    static func checkForUpdates() {
        shared.checkForUpdates(nil)
    }
}
