import Foundation
import Testing
@testable import DKBMonitorCore
@testable import DKB_Monitor

@Suite struct JunkCleanerServiceTests {
    private let home = "/Users/example"

    private func target(
        name: String = "Cache", path: String, deletesPermanently: Bool
    ) -> JunkTarget {
        JunkTarget(
            name: name, detail: "", path: path,
            mode: .contents, deletesPermanently: deletesPermanently
        )
    }

    /// The Trash is the one place the app deletes outright, because it cannot
    /// be moved into itself.
    @Test func theTrashMaySkipTheTrash() {
        let trash = target(name: "Trash", path: home + "/.Trash", deletesPermanently: true)
        #expect(JunkCleanerService.maySkipTheTrash(trash, homeDirectory: home))
    }

    /// The regression this guards: permission to delete outright is pinned to
    /// the path, not to the flag. A future target copy-pasted with
    /// `deletesPermanently: true` still only reaches the Trash, so the
    /// mistake costs nothing instead of destroying a cache tree for good.
    @Test func aNonTrashTargetNeverSkipsTheTrashEvenWhenItClaimsTo() {
        let mislabelled = target(path: home + "/Library/Caches", deletesPermanently: true)
        #expect(!JunkCleanerService.maySkipTheTrash(mislabelled, homeDirectory: home))
    }

    @Test func anOrdinaryTargetDoesNotSkipTheTrash() {
        let ordinary = target(path: home + "/Library/Caches", deletesPermanently: false)
        #expect(!JunkCleanerService.maySkipTheTrash(ordinary, homeDirectory: home))
    }

    /// A relocated cache — moved to another volume and symlinked back — must
    /// be recognised, because `contentsOfDirectory` follows the link and would
    /// empty the destination instead of the folder the user selected.
    @Test func detectsASymlinkedTargetPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JunkCleanerServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real-cache")
        let link = root.appendingPathComponent("linked-cache")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(JunkCleanerService.isRelocated(link.path))
        #expect(!JunkCleanerService.isRelocated(real.path))
    }
}
