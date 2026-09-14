import Foundation

/// One file found by the large-file scan.
public struct LargeFileEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64
    public let modified: Date

    public init(path: String, sizeBytes: Int64, modified: Date) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// Containing folder, with `$HOME` collapsed to `~` — the full path is
    /// usually far too long for a table column.
    public var folder: String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return home.isEmpty ? parent : parent.replacingOccurrences(of: home, with: "~")
    }
}

/// Where a scan can start. Presets cover the folders that actually
/// accumulate large files; the user can also pick any folder.
public struct ScanRoot: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let title: String
    public let path: String

    public init(title: String, path: String) {
        self.title = title
        self.path = path
    }

    public static func presets(homeDirectory: String) -> [ScanRoot] {
        [
            ScanRoot(title: "Home", path: homeDirectory),
            ScanRoot(title: "Downloads", path: homeDirectory + "/Downloads"),
            ScanRoot(title: "Desktop", path: homeDirectory + "/Desktop"),
            ScanRoot(title: "Documents", path: homeDirectory + "/Documents"),
            ScanRoot(title: "Movies", path: homeDirectory + "/Movies"),
            ScanRoot(title: "Library", path: homeDirectory + "/Library"),
            ScanRoot(title: "Applications", path: "/Applications"),
        ]
    }

    /// Subtrees a scan must never walk into: the sealed system volume, other
    /// mounted volumes (a scan of `~` shouldn't wander onto a NAS), the VM
    /// swap store, and Spotlight/Time Machine bookkeeping. Walking these
    /// wastes minutes and returns nothing the user can act on.
    public static let excludedPrefixes = [
        "/System", "/Volumes", "/dev", "/net", "/Network",
        "/private/var/vm", "/private/var/db",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
    ]

    public static func isExcluded(_ path: String) -> Bool {
        excludedPrefixes.contains { path.hasPrefix($0) }
    }
}
