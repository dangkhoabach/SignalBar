import Foundation
import Testing
@testable import SignalBarCore
@testable import SignalBar

/// Builds a throwaway directory tree under the system temp directory, so the
/// scanner runs against real `FileManager` enumeration rather than a fake —
/// package skipping and cancellation are both behaviours of the enumerator
/// itself, and a stub would prove nothing about either.
private struct TempTree {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LargeFileScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct LargeFileScannerTests {
    /// The regression this suite exists for: `/Applications` is a preset scan
    /// root, so without `.skipsPackageDescendants` the biggest files on the
    /// machine are bundle internals, sorted straight to the top of a list
    /// whose next button moves them to the Trash.
    @Test func doesNotReturnFilesFromInsideAnAppBundle() async throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        _ = try tree.makeFile("Demo.app/Contents/MacOS/Demo", bytes: 4096)
        _ = try tree.makeFile("loose-file.bin", bytes: 4096)

        let outcome = await LargeFileScanner().scan(
            root: tree.root.path, minimumBytes: 1024, includeHidden: false
        ) { _ in }

        #expect(outcome.entries.count == 1)
        #expect(outcome.entries.first?.name == "loose-file.bin")
        #expect(!outcome.entries.contains { $0.path.contains("Demo.app") })
    }

    /// Hidden files are still opt-in after the package-skip option was added
    /// alongside `.skipsHiddenFiles` — the two are independent.
    @Test func honoursTheHiddenFilesToggleIndependentlyOfPackageSkipping() async throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        _ = try tree.makeFile(".hidden.bin", bytes: 4096)

        let scanner = LargeFileScanner()
        let excluded = await scanner.scan(root: tree.root.path, minimumBytes: 1024, includeHidden: false) { _ in }
        let included = await scanner.scan(root: tree.root.path, minimumBytes: 1024, includeHidden: true) { _ in }

        #expect(excluded.entries.isEmpty)
        #expect(included.entries.count == 1)
    }

    /// `Task.detached` doesn't inherit cancellation, so the walk needs a flag
    /// of its own. Cancelling the calling task has to actually stop it —
    /// before this, "Stop" only changed the UI while the walk ran to the end.
    @Test func cancellingTheCallingTaskStopsTheWalk() async throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        for index in 0..<400 {
            _ = try tree.makeFile("folder\(index % 20)/file\(index).bin", bytes: 1024)
        }

        let scanner = LargeFileScanner()
        let task = Task {
            await scanner.scan(root: tree.root.path, minimumBytes: 1, includeHidden: true) { _ in }
        }
        task.cancel()
        let outcome = await task.value

        // The walk observes the flag at the top of each iteration, so it stops
        // early rather than returning the whole tree. Asserting "fewer than
        // everything" rather than an exact count keeps this from depending on
        // how fast the cancel lands.
        #expect(outcome.scannedFiles < 400)
    }

    /// A result list can outlive the scan that produced it, so the deletion
    /// path re-checks rather than trusting that the walk already filtered.
    @Test func refusesToTrashAPathInsideAPackage() async throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        let inside = try tree.makeFile("Demo.app/Contents/MacOS/Demo", bytes: 1024)

        #expect(LargeFileScanner.isInsidePackage(inside.path))

        let result = await LargeFileScanner().moveToTrash([
            LargeFileEntry(path: inside.path, sizeBytes: 1024, modified: .distantPast)
        ])

        #expect(result.freedBytes == 0)
        #expect(result.trashedPaths.isEmpty)
        #expect(result.failedNames == ["Demo"])
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    @Test func allowsTrashingAPathOutsideAnyPackage() throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        let loose = try tree.makeFile("loose-file.bin", bytes: 1024)

        #expect(!LargeFileScanner.isInsidePackage(loose.path))
    }
}
