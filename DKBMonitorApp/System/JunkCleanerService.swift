import AppKit
import DKBMonitorCore
import Foundation

/// Measures and clears the `JunkTarget` locations.
///
/// Everything is moved to the Trash rather than deleted, with the single
/// exception of the Trash itself — so a wrong guess about what was safe to
/// remove stays recoverable. Deletion is never initiated here; the view asks
/// for confirmation first.
///
/// An `actor`, like `ProcessListService`: measuring walks tens of thousands
/// of files across a dozen directories, which must never run on the main
/// actor, and the concurrent `measure` calls need the results serialised.
actor JunkCleanerService {
    /// Directory size in bytes, keyed by target path.
    struct Measurement: Sendable {
        var path: String
        var bytes: Int64
    }

    /// Resolved on first access rather than in `init`.
    ///
    /// The filter below stats sixteen paths, and `init` runs wherever the
    /// owner is created — for the shared view model, that was the main actor
    /// during view setup. `lazy` inside an actor moves the work to the first
    /// `await` on this property, which every caller already does.
    lazy var targets: [JunkTarget] = {
        if let overrideTargets { return overrideTargets }
        // Filtered to what exists: listing "Gradle cache — 0 bytes" on a Mac
        // with no Gradle is noise, and the list is long enough already.
        let fileManager = FileManager.default
        return JunkTarget.defaults(homeDirectory: NSHomeDirectory())
            .filter { fileManager.fileExists(atPath: $0.path) }
    }()

    /// Set only by tests, which point the cleaner at a temporary directory
    /// instead of the real caches under `~`.
    private let overrideTargets: [JunkTarget]?

    init(targets: [JunkTarget]? = nil) {
        self.overrideTargets = targets
    }

    /// Measures every target concurrently. Yields each result as it lands so
    /// the UI can fill in progressively — a cold `~/Library/Caches` walk can
    /// take several seconds on its own, and waiting for the slowest target
    /// before showing any number at all felt broken.
    func measureAll() -> AsyncStream<Measurement> {
        let paths = targets.map(\.path)
        return AsyncStream { continuation in
            Task.detached(priority: .utility) {
                await withTaskGroup(of: Measurement.self) { group in
                    for path in paths {
                        group.addTask { Measurement(path: path, bytes: Self.directorySize(at: path)) }
                    }
                    for await measurement in group {
                        continuation.yield(measurement)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Recursive allocated size of a directory. Symlinks are skipped so a
    /// link into another target isn't counted twice; unreadable subtrees are
    /// stepped over rather than aborting the walk.
    nonisolated static func directorySize(at path: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    enum CleanError: Error {
        /// The target path is a symlink pointing somewhere this service never
        /// measured — cleaning it would delete files the user never saw listed.
        case relocatedTarget
    }

    struct CleanResult: Sendable {
        var freedBytes: Int64
        /// Targets that couldn't be fully cleared, by name — almost always a
        /// permissions issue (a cache owned by a sandboxed app).
        var skipped: [String]
    }

    /// Clears the selected targets. `knownSizes` supplies the already-measured
    /// byte counts so the freed total doesn't require re-walking each tree.
    func clean(paths: Set<String>, knownSizes: [String: Int64]) -> CleanResult {
        var freed: Int64 = 0
        var skipped: [String] = []

        // Emptying `~/Library/Caches` already removes the Homebrew and pip
        // caches nested inside it, so cleaning those again would only fail on
        // directories that are already gone.
        let selected = JunkTarget.withoutNested(targets.filter { paths.contains($0.path) })

        for target in selected {
            do {
                let outcome = try remove(target, knownSize: knownSizes[target.path] ?? 0)
                freed += outcome.freedBytes
                if outcome.incomplete { skipped.append(target.name) }
            } catch {
                skipped.append(target.name)
            }
        }
        return CleanResult(freedBytes: freed, skipped: skipped)
    }

    private struct RemovalOutcome {
        var freedBytes: Int64
        /// Something in the target survived — a locked file, or one owned by
        /// another app. The rest still went.
        var incomplete: Bool
    }

    /// The only path allowed to bypass the Trash.
    ///
    /// `deletesPermanently` is set on exactly one target, but nothing stopped
    /// a future one from being copy-pasted with the flag still `true` — which
    /// would `removeItem` a real cache tree outright while the confirmation
    /// dialog still promised the Trash. Pinning the permission to the path
    /// rather than the flag makes that mistake impossible to make silently.
    nonisolated static func maySkipTheTrash(_ target: JunkTarget, homeDirectory: String = NSHomeDirectory()) -> Bool {
        target.deletesPermanently && target.path == homeDirectory + "/.Trash"
    }

    /// True when the target path is itself a symlink.
    ///
    /// People really do move `~/Library/Caches` or `~/.npm` onto another
    /// volume and link it back. `contentsOfDirectory` follows the link, so
    /// cleaning would empty whatever it points at — somewhere this service
    /// never audited and the user never picked. Children don't need this:
    /// `trashItem` on a symlink takes the link, not its destination.
    nonisolated static func isRelocated(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func remove(_ target: JunkTarget, knownSize: Int64) throws -> RemovalOutcome {
        let fileManager = FileManager.default
        guard !Self.isRelocated(target.path) else { throw CleanError.relocatedTarget }
        let skipsTheTrash = Self.maySkipTheTrash(target)

        func delete(_ url: URL) throws {
            if skipsTheTrash {
                try fileManager.removeItem(at: url)
            } else {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            }
        }

        switch target.mode {
        case .item:
            try delete(URL(fileURLWithPath: target.path))
            return RemovalOutcome(freedBytes: knownSize, incomplete: false)
        case .contents:
            let children = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: target.path), includingPropertiesForKeys: nil
            )
            // Keeps going after a failure instead of stopping at the first
            // locked file: one undeletable cache entry shouldn't leave the
            // other 4 GB in place.
            var failures = 0
            for child in children {
                do { try delete(child) } catch { failures += 1 }
            }
            guard failures > 0 else {
                return RemovalOutcome(freedBytes: knownSize, incomplete: false)
            }
            // A single locked file used to throw away the whole figure:
            // clearing 8 GB with one undeletable entry reported "Freed 0
            // bytes". Re-measuring says what actually went, and only costs a
            // second walk in the case that already went wrong.
            let remaining = Self.directorySize(at: target.path)
            return RemovalOutcome(freedBytes: max(0, knownSize - remaining), incomplete: true)
        }
    }
}
