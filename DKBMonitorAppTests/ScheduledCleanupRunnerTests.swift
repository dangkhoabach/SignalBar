import Foundation
import Testing
@testable import DKBMonitorCore
@testable import DKB_Monitor

/// The runner is thin on purpose, so the one thing worth pinning is the one
/// thing it must supply itself: the sizes the cleaner reports from. Without
/// them every scheduled run announced "Moved Zero KB".
@Suite struct ScheduledCleanupRunnerTests {
    /// A real directory under the temp root, with real bytes in it. The run
    /// moves that file to the Trash — the only honest way to test this path,
    /// since the freed figure is computed around the removal itself. It is a
    /// few kilobytes, named after this suite, and lands in the user's Trash
    /// like any other cleaned item.
    private func makeTarget(bytes: Int) throws -> (JunkTarget, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("ScheduledCleanupRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: root.appendingPathComponent("cache.bin"))
        let target = JunkTarget(
            name: "Test cache", detail: "", path: root.path, mode: .contents, deletesPermanently: false
        )
        return (target, root)
    }

    @Test func reportsWhatItActuallyMoved() async throws {
        let (target, root) = try makeTarget(bytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let measured = JunkCleanerService.directorySize(at: root.path)
        #expect(measured > 0)

        let runner = ScheduledCleanupRunner(service: JunkCleanerService(targets: [target]))
        let result = await runner.clean([target])

        #expect(result.bytes == measured)
        #expect(result.skipped.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func offersTheServiceOwnTargets() async throws {
        let (target, root) = try makeTarget(bytes: 16)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ScheduledCleanupRunner(service: JunkCleanerService(targets: [target]))

        #expect(await runner.availableTargets().map(\.path) == [target.path])
    }
}
