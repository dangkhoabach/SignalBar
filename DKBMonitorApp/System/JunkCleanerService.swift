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

    let targets: [JunkTarget]

    init() {
        // Filtered to what exists: listing "Gradle cache — 0 bytes" on a Mac
        // with no Gradle is noise, and the list is long enough already.
        let fileManager = FileManager.default
        targets = JunkTarget.defaults(homeDirectory: NSHomeDirectory())
            .filter { fileManager.fileExists(atPath: $0.path) }
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

        for target in targets where paths.contains(target.path) {
            do {
                try remove(target)
                freed += knownSizes[target.path] ?? 0
            } catch {
                skipped.append(target.name)
            }
        }
        return CleanResult(freedBytes: freed, skipped: skipped)
    }

    private func remove(_ target: JunkTarget) throws {
        let fileManager = FileManager.default

        func delete(_ url: URL) throws {
            if target.deletesPermanently {
                try fileManager.removeItem(at: url)
            } else {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            }
        }

        switch target.mode {
        case .item:
            try delete(URL(fileURLWithPath: target.path))
        case .contents:
            let children = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: target.path), includingPropertiesForKeys: nil
            )
            // Keeps going after a failure instead of stopping at the first
            // locked file: one undeletable cache entry shouldn't leave the
            // other 4 GB in place. The last error still surfaces as "skipped".
            var lastError: Error?
            for child in children {
                do { try delete(child) } catch { lastError = error }
            }
            if let lastError { throw lastError }
        }
    }
}
