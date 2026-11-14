import AppKit
import SwiftUI

/// The About window: the icon, the name and what the app does, its version
/// and release date, the copyright and links to its page and its source.
/// It replaces the standard panel, which shows only the name and version.
@MainActor
enum AboutWindow {
    static let name = "SignalBar"
    static let summary: LocalizedStringKey = "Your websites and servers, watched from the menu bar."
    static let website = URL(string: "https://apps.dangkhoabach.vn/dkb-monitor")!
    static let source = URL(string: "https://github.com/dangkhoabach/SignalBar")!

    private static var window: NSWindow?

    /// Made again each time it opens, so it follows the language chosen in
    /// Settings since; brought forward when already open.
    static func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingView(rootView: AboutView().environment(\.locale, AppLocale.selected.locale))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "About SignalBar", bundle: AppLocale.bundle)
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// What the About window reads from Info.plist.
struct AboutInfo: Equatable {
    var version: String
    var build: String
    /// `AppReleaseDate`, which scripts/release.sh writes with the version.
    var releaseDate: DateComponents?

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
        let parts = (info["AppReleaseDate"] as? String)?.split(separator: "-").compactMap { Int($0) } ?? []
        releaseDate = parts.count == 3 ? DateComponents(year: parts[0], month: parts[1], day: parts[2]) : nil
    }

    /// The build in brackets only when it says something the version doesn't.
    var versionText: String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }

    /// The release day as a date at noon, so no time zone moves it to another day.
    var releaseDay: Date? {
        guard var components = releaseDate else { return nil }
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

struct AboutView: View {
    private let info = AboutInfo(info: Bundle.main.infoDictionary ?? [:])
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: AboutWindow.name)
                .font(.title2.bold())
                .padding(.top, 10)
            Text(AboutWindow.summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(spacing: 2) {
                Text("Version \(info.versionText)")
                if let day = info.releaseDay {
                    Text("Released \(day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)))")
                }
            }
            .padding(.top, 14)
            Text(verbatim: "© 2026 Bạch Thái Đăng Khoa")
                .padding(.top, 14)
            HStack(spacing: 18) {
                Link("Website", destination: AboutWindow.website)
                Link(destination: AboutWindow.source) { Text(verbatim: "GitHub") }
            }
            .padding(.top, 14)
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 320)
    }
}
