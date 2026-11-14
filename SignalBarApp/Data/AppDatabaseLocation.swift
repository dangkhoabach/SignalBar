import Foundation

/// Resolves to the exact same path the Tauri app already writes to —
/// `~/Library/Application Support/<bundle id>/dkb-monitor.db`: this
/// is an in-place upgrade that reads the existing database, not a fresh one
/// under a new identity.
enum AppDatabaseLocation {
    static func productionPath() -> URL {
        if let testPath = testHostPath() { return testPath }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dangkhoabach.dkb-monitor"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dkb-monitor.db")
    }

    /// Running as the unit tests' host, the app gets a database of its own in
    /// a temporary folder. The host launches like the real app, so with the
    /// real path every test run migrated the user's database to whatever
    /// schema the branch under test had, and let the scheduler write to it.
    private static func testHostPath() -> URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignalBarTestHost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dkb-monitor.db")
    }
}
