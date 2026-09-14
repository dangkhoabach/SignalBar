import AppKit
import DKBMonitorCore
import Foundation

/// Walks a directory tree for files above a size threshold.
///
/// The walk is synchronous and potentially very long (a full `~` scan visits
/// hundreds of thousands of entries), so it runs detached off the main actor
/// and checks `Task.isCancelled` each iteration — the view cancels it when
/// the user changes root or leaves the tab.
actor LargeFileScanner {
    struct Progress: Sendable {
        var scannedFiles: Int
        var currentFolder: String
    }

    struct Outcome: Sendable {
        var entries: [LargeFileEntry]
        var scannedFiles: Int
        var matchedBytes: Int64
        /// Set when the root itself couldn't be opened — a folder the app has
        /// no permission for (Desktop/Documents without the TCC grant).
        var errorMessage: String?
    }

    /// Caps the result list. The point is to surface the biggest offenders,
    /// and a table of 50,000 rows helps nobody — the total bytes matched is
    /// reported separately so nothing is silently hidden.
    private static let resultLimit = 500

    func scan(
        root: String,
        minimumBytes: Int64,
        includeHidden: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Outcome {
        await Task.detached(priority: .utility) {
            Self.walk(root: root, minimumBytes: minimumBytes, includeHidden: includeHidden, onProgress: onProgress)
        }.value
    }

    private nonisolated static func walk(
        root: String,
        minimumBytes: Int64,
        includeHidden: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) -> Outcome {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentModificationDateKey, .isSymbolicLinkKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return Outcome(entries: [], scannedFiles: 0, matchedBytes: 0,
                           errorMessage: "Could not open that folder.")
        }

        var found: [LargeFileEntry] = []
        var scanned = 0
        var matched: Int64 = 0

        for case let url as URL in enumerator {
            if Task.isCancelled { break }

            if ScanRoot.isExcluded(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true
            else { continue }

            scanned += 1
            if values.isRegularFile == true {
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                if size >= minimumBytes {
                    found.append(LargeFileEntry(
                        path: url.path,
                        sizeBytes: size,
                        modified: values.contentModificationDate ?? .distantPast
                    ))
                    matched += size
                }
            }
            // Reported every few thousand entries rather than per file: a
            // main-actor hop per file would cost more than the walk itself.
            if scanned % 4000 == 0 {
                onProgress(Progress(scannedFiles: scanned, currentFolder: url.deletingLastPathComponent().path))
            }
        }

        return Outcome(
            entries: Array(found.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(resultLimit)),
            scannedFiles: scanned,
            matchedBytes: matched,
            errorMessage: nil
        )
    }

    struct TrashResult: Sendable {
        var freedBytes: Int64
        var trashedPaths: Set<String>
        var failedNames: [String]
    }

    /// Moves files to the Trash — never `removeItem`. A size-ranked list
    /// invites fast clicking, so every deletion here has to stay undoable.
    func moveToTrash(_ entries: [LargeFileEntry]) -> TrashResult {
        var freed: Int64 = 0
        var trashed: Set<String> = []
        var failed: [String] = []

        for entry in entries {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                freed += entry.sizeBytes
                trashed.insert(entry.path)
            } catch {
                failed.append(entry.name)
            }
        }
        return TrashResult(freedBytes: freed, trashedPaths: trashed, failedNames: failed)
    }
}
