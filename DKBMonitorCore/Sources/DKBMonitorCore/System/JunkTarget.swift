import Foundation

/// One cleanable location: a cache directory, a build-artifact folder, the
/// Trash. Describes *what* to clean — the measuring and deleting live in the
/// app target's `JunkCleanerService`, which needs AppKit to move items to
/// the Trash rather than destroying them outright.
public struct JunkTarget: Sendable, Equatable, Identifiable {
    public enum Mode: Sendable, Equatable {
        /// Empty the folder but keep the folder itself — deleting
        /// `~/Library/Caches` outright breaks apps that expect it to exist.
        case contents
        /// Delete the item itself.
        case item
    }

    public var id: String { path }
    public let name: String
    /// Shown under the name: what this is and what losing it costs.
    public let detail: String
    public let path: String
    public let mode: Mode
    /// Skip the Trash and delete outright. Only true for the Trash itself,
    /// which obviously cannot be moved into the Trash.
    public let deletesPermanently: Bool

    public init(name: String, detail: String, path: String, mode: Mode, deletesPermanently: Bool) {
        self.name = name
        self.detail = detail
        self.path = path
        self.mode = mode
        self.deletesPermanently = deletesPermanently
    }

    /// Path with `$HOME` collapsed back to `~` for display.
    public var displayPath: String {
        let home = NSHomeDirectory()
        return home.isEmpty ? path : path.replacingOccurrences(of: home, with: "~")
    }

    /// Every location this app knows how to clean, in the order shown.
    ///
    /// Deliberately excludes anything whose loss isn't purely a rebuild
    /// cost: no `~/Library/Containers` app data, no Simulator *devices*
    /// (which hold real app state), no Docker volumes. Every entry here
    /// either regenerates on next use or is already garbage.
    public static func defaults(homeDirectory: String) -> [JunkTarget] {
        func path(_ suffix: String) -> String { homeDirectory + "/" + suffix }
        return [
            JunkTarget(name: "Trash", detail: "Permanently empties ~/.Trash",
                       path: path(".Trash"), mode: .contents, deletesPermanently: true),
            JunkTarget(name: "App caches", detail: "~/Library/Caches — apps rebuild these on demand",
                       path: path("Library/Caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Logs", detail: "~/Library/Logs",
                       path: path("Library/Logs"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode DerivedData", detail: "Build cache, regenerated on the next build",
                       path: path("Library/Developer/Xcode/DerivedData"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode iOS DeviceSupport", detail: "Symbols for every iOS version this Mac has connected to",
                       path: path("Library/Developer/Xcode/iOS DeviceSupport"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode Archives", detail: "Past archives — check before deleting",
                       path: path("Library/Developer/Xcode/Archives"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Simulator caches", detail: "~/Library/Developer/CoreSimulator/Caches",
                       path: path("Library/Developer/CoreSimulator/Caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "SwiftPM cache", detail: "Cloned package checkouts, re-fetched on demand",
                       path: path("Library/Caches/org.swift.swiftpm"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "NuGet packages", detail: "~/.nuget/packages — restored by the next build",
                       path: path(".nuget/packages"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "npm cache", detail: "~/.npm/_cacache",
                       path: path(".npm/_cacache"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Yarn cache", detail: "~/Library/Caches/Yarn",
                       path: path("Library/Caches/Yarn"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "pnpm store", detail: "~/Library/pnpm/store",
                       path: path("Library/pnpm/store"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "pip cache", detail: "~/Library/Caches/pip",
                       path: path("Library/Caches/pip"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Gradle cache", detail: "~/.gradle/caches",
                       path: path(".gradle/caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "CocoaPods cache", detail: "~/Library/Caches/CocoaPods",
                       path: path("Library/Caches/CocoaPods"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Homebrew cache", detail: "Downloaded bottles, re-fetched on demand",
                       path: path("Library/Caches/Homebrew"), mode: .contents, deletesPermanently: false),
        ]
    }
}
