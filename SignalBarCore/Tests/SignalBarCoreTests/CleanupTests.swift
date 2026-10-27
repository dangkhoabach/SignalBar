import Foundation
import Testing
@testable import SignalBarCore

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

/// Nesting is by design in the default list — several tool caches live
/// inside `~/Library/Caches`, which is itself a target.
@Suite struct JunkTargetNestingTests {
    private func target(_ path: String) -> JunkTarget {
        JunkTarget(name: path, detail: "", path: path, mode: .contents, deletesPermanently: false)
    }

    /// The regression on the counting side: summing every measured target
    /// counted the nested caches once for themselves and again inside the
    /// parent, overstating what was actually reclaimable.
    @Test func dropsTargetsNestedInsideAnotherTarget() {
        let targets = [
            target("/Users/example/Library/Caches"),
            target("/Users/example/Library/Caches/Homebrew"),
            target("/Users/example/Library/Caches/pip"),
            target("/Users/example/Library/Logs"),
        ]
        let kept = JunkTarget.withoutNested(targets).map(\.path)
        #expect(kept == ["/Users/example/Library/Caches", "/Users/example/Library/Logs"])
    }

    /// And on the cleaning side: without the parent selected there is nothing
    /// to be nested inside, so the child must survive on its own.
    @Test func keepsANestedTargetWhenItsParentIsNotInTheList() {
        let targets = [
            target("/Users/example/Library/Caches/Homebrew"),
            target("/Users/example/Library/Logs"),
        ]
        #expect(JunkTarget.withoutNested(targets).count == 2)
    }

    /// A shared prefix that isn't a real parent directory must not count:
    /// `Caches2` is not inside `Caches`.
    @Test func doesNotTreatASharedNamePrefixAsNesting() {
        let targets = [
            target("/Users/example/Library/Caches"),
            target("/Users/example/Library/Caches2"),
        ]
        #expect(JunkTarget.withoutNested(targets).count == 2)
    }

    /// The real default list has known nesting, and the de-nested version of
    /// it must still contain the parent rather than dropping everything.
    @Test func handlesTheRealDefaultList() {
        let defaults = JunkTarget.defaults(homeDirectory: "/Users/example")
        let kept = JunkTarget.withoutNested(defaults)
        #expect(kept.count < defaults.count)
        #expect(kept.contains { $0.path == "/Users/example/Library/Caches" })
        #expect(!kept.contains { $0.path == "/Users/example/Library/Caches/Homebrew" })
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
