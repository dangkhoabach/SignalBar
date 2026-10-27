import AppKit
import SignalBarCore
import Foundation
import Observation

/// Drives the Cleanup pane's two halves — junk locations and the large-file
/// scan. One view model for both because they share the pane, the "freed
/// space" message, and nothing else; splitting them would mean two objects
/// that always appear together.
@MainActor
@Observable
final class CleanupViewModel {
    static let shared = CleanupViewModel()

    private let cleaner = JunkCleanerService()
    private let scanner = LargeFileScanner()

    // MARK: - Junk

    var junkTargets: [JunkTarget] = []
    /// Measured size per target path. Absent while a measurement is still
    /// running, which is what the row's placeholder keys off.
    var junkSizes: [String: Int64] = [:]
    var junkSelection: Set<String> = []
    var isMeasuring = false
    var statusMessage: String?

    /// Nested targets are excluded from both totals: the Homebrew, pip and
    /// Yarn caches live inside `~/Library/Caches`, so adding every measured
    /// target together counted those bytes twice.
    var totalJunkBytes: Int64 {
        JunkTarget.withoutNested(junkTargets).reduce(0) { $0 + (junkSizes[$1.path] ?? 0) }
    }

    var selectedJunkBytes: Int64 {
        JunkTarget.withoutNested(junkTargets.filter { junkSelection.contains($0.path) })
            .reduce(0) { $0 + (junkSizes[$1.path] ?? 0) }
    }

    func loadTargets() async {
        guard junkTargets.isEmpty else { return }
        junkTargets = await cleaner.targets
    }

    func measureJunk() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        statusMessage = nil
        for await measurement in await cleaner.measureAll() {
            junkSizes[measurement.path] = measurement.bytes
        }
        isMeasuring = false
    }

    /// Called only after the view's confirmation dialog is accepted.
    func cleanSelected() async {
        let paths = junkSelection
        guard !paths.isEmpty else { return }
        let result = await cleaner.clean(paths: paths, knownSizes: junkSizes)

        // "Freed" only fits the Trash, which is emptied outright. Everything
        // else moves to the Trash, where it still occupies the disk until the
        // user empties it — claiming the space was freed would be a lie the
        // Finder immediately contradicts.
        let emptiedTheTrash = junkTargets.contains { paths.contains($0.path) && $0.deletesPermanently }
        let moved = Self.formatBytes(result.freedBytes)
        let headline = emptiedTheTrash ? "Freed \(moved)." : "Moved \(moved) to the Trash."

        junkSelection.removeAll()
        // Deliberately not "no permission": a target can also be skipped for
        // being a relocated symlink, or partly cleaned with a few locked
        // files left behind. Naming a cause the app didn't establish sent
        // people to check permissions that were never the problem.
        statusMessage = result.skipped.isEmpty
            ? headline
            : "\(headline) Not fully cleared: \(result.skipped.joined(separator: ", "))"

        await measureJunk()
    }

    // MARK: - Large files

    var scanRoots: [ScanRoot] = []
    var selectedRootPath: String = ""
    /// Threshold in MB. 100 MB is a useful default: low enough to catch old
    /// installers and video files, high enough that `~` doesn't return
    /// thousands of rows.
    var minimumMB: Int = 100
    var includeHidden = false

    var scanResults: [LargeFileEntry] = []
    var fileSelection: Set<String> = []
    var isScanning = false
    var scannedFiles = 0
    var currentFolder = ""
    var matchedBytes: Int64 = 0
    var scanErrorMessage: String?
    var hasScanned = false

    private var scanTask: Task<Void, Never>?
    /// Bumped per scan so a progress callback still in flight from a cancelled
    /// walk can't write its (much larger) file count over the new scan's
    /// freshly reset counter.
    private var scanGeneration = 0

    func loadScanRoots() {
        guard scanRoots.isEmpty else { return }
        let fileManager = FileManager.default
        scanRoots = ScanRoot.presets(homeDirectory: NSHomeDirectory())
            .filter { fileManager.fileExists(atPath: $0.path) }
        selectedRootPath = scanRoots.first { $0.title == "Downloads" }?.path ?? scanRoots.first?.path ?? ""
    }

    func startScan() {
        guard !selectedRootPath.isEmpty else { return }
        cancelScan()

        scanResults = []
        fileSelection = []
        scannedFiles = 0
        matchedBytes = 0
        scanErrorMessage = nil
        currentFolder = selectedRootPath
        isScanning = true

        let root = selectedRootPath
        let minimumBytes = Int64(minimumMB) * 1_048_576
        let includeHidden = includeHidden
        scanGeneration += 1
        let generation = scanGeneration

        scanTask = Task { [weak self] in
            // Bound strongly up front so the `@Sendable` progress closure
            // below captures an immutable reference — capturing the outer
            // optional `self` directly is a mutable capture and won't compile.
            guard let self else { return }
            let outcome = await self.scanner.scan(
                root: root, minimumBytes: minimumBytes, includeHidden: includeHidden
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scannedFiles = progress.scannedFiles
                    self.currentFolder = progress.currentFolder
                }
            }
            guard !Task.isCancelled else { return }
            self.scanResults = outcome.entries
            self.scannedFiles = outcome.scannedFiles
            self.matchedBytes = outcome.matchedBytes
            self.scanErrorMessage = outcome.errorMessage
            self.currentFolder = ""
            self.isScanning = false
            self.hasScanned = true
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentFolder = ""
    }

    func revealSelectedFiles() {
        let urls = scanResults.filter { fileSelection.contains($0.path) }.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Called only after the view's confirmation dialog is accepted.
    func trashSelectedFiles() async {
        let entries = scanResults.filter { fileSelection.contains($0.path) }
        guard !entries.isEmpty else { return }
        let result = await scanner.moveToTrash(entries)

        scanResults.removeAll { result.trashedPaths.contains($0.path) }
        fileSelection.removeAll()
        matchedBytes = scanResults.reduce(0) { $0 + $1.sizeBytes }
        statusMessage = result.failedNames.isEmpty
            ? "Moved \(Self.formatBytes(result.freedBytes)) to the Trash."
            : "Moved \(Self.formatBytes(result.freedBytes)) to the Trash. Could not delete: \(result.failedNames.prefix(3).joined(separator: ", "))"
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
