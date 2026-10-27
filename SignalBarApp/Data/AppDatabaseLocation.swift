import Foundation

/// Resolves to the exact same path the Tauri app already writes to —
/// `~/Library/Application Support/<bundle id>/dkb-monitor.db`: this
/// is an in-place upgrade that reads the existing database, not a fresh one
/// under a new identity.
enum AppDatabaseLocation {
    static func productionPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dangkhoabach.dkb-monitor"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dkb-monitor.db")
    }
}
