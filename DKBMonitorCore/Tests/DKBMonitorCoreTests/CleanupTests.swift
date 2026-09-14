import Foundation
import Testing
@testable import DKBMonitorCore

@Suite struct JunkTargetTests {
    private let targets = JunkTarget.defaults(homeDirectory: "/Users/test")

    @Test func buildsPathsUnderTheGivenHome() {
        let derivedData = targets.first { $0.name == "Xcode DerivedData" }
        #expect(derivedData?.path == "/Users/test/Library/Developer/Xcode/DerivedData")
    }

    /// The single most important invariant in this feature: everything is
    /// recoverable from the Trash except the Trash, which by definition
    /// cannot be moved into itself.
    @Test func onlyTheTrashDeletesPermanently() {
        let permanent = targets.filter(\.deletesPermanently)
        #expect(permanent.count == 1)
        #expect(permanent.first?.name == "Trash")
    }

    /// Emptying `~/Library/Caches` is fine; deleting the folder itself
    /// breaks apps that assume it exists.
    @Test func cacheDirectoriesAreClearedByContentsNotRemoved() {
        #expect(targets.allSatisfy { $0.mode == .contents })
    }

    /// Guards against a future entry that would destroy real user data
    /// rather than a rebuildable cache.
    @Test func neverTargetsAppContainersOrSimulatorDevices() {
        #expect(!targets.contains { $0.path.contains("CoreSimulator/Devices") })
        #expect(!targets.contains { $0.path.contains("Library/Containers") })
    }

    @Test func displayPathCollapsesTheHomeDirectory() {
        let target = JunkTarget(name: "T", detail: "", path: NSHomeDirectory() + "/Library/Caches",
                                mode: .contents, deletesPermanently: false)
        #expect(target.displayPath == "~/Library/Caches")
    }

    @Test func pathsAreUniqueSoSelectionIdsDoNotCollide() {
        #expect(Set(targets.map(\.path)).count == targets.count)
    }
}

@Suite struct ScanRootTests {
    /// A scan of `~` must not wander onto the sealed system volume or a
    /// mounted NAS — that turns a 30-second scan into a multi-minute one
    /// returning files the user can't act on anyway.
    @Test func excludesSystemAndMountedVolumes() {
        #expect(ScanRoot.isExcluded("/System/Library/Frameworks"))
        #expect(ScanRoot.isExcluded("/Volumes/Backup/big.dmg"))
        #expect(ScanRoot.isExcluded("/private/var/vm/swapfile0"))
        #expect(ScanRoot.isExcluded("/.Spotlight-V100/Store"))
    }

    @Test func allowsOrdinaryUserPaths() {
        #expect(!ScanRoot.isExcluded("/Users/test/Downloads/video.mov"))
        #expect(!ScanRoot.isExcluded("/Applications/Xcode.app"))
    }

    @Test func presetsAreRootedAtTheGivenHome() {
        let roots = ScanRoot.presets(homeDirectory: "/Users/test")
        #expect(roots.first { $0.title == "Downloads" }?.path == "/Users/test/Downloads")
        #expect(roots.first { $0.title == "Applications" }?.path == "/Applications")
    }
}

@Suite struct LargeFileEntryTests {
    @Test func splitsNameAndFolder() {
        let entry = LargeFileEntry(path: NSHomeDirectory() + "/Downloads/big.zip", sizeBytes: 5_000, modified: .now)
        #expect(entry.name == "big.zip")
        #expect(entry.folder == "~/Downloads")
    }

    @Test func folderOutsideHomeKeepsItsAbsolutePath() {
        let entry = LargeFileEntry(path: "/Applications/Xcode.app", sizeBytes: 1, modified: .now)
        #expect(entry.folder == "/Applications")
    }
}
