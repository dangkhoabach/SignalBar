import AppKit
import Testing
@testable import SignalBar

@MainActor
@Suite struct AboutWindowTests {
    @Test func readsTheVersionAndTheReleaseDay() throws {
        let info = AboutInfo(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "1.2.0", "AppReleaseDate": "2026-11-14"])
        #expect(info.versionText == "1.2.0")
        let day = try #require(info.releaseDay)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: day)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 14)
    }

    @Test func showsTheBuildOnlyWhenItDiffers() {
        #expect(AboutInfo(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "57"]).versionText == "1.2.0 (57)")
        #expect(AboutInfo(info: ["CFBundleShortVersionString": "1.2.0"]).versionText == "1.2.0")
    }

    @Test func leavesTheDateOutWhenThereIsNone() {
        #expect(AboutInfo(info: ["AppReleaseDate": "soon"]).releaseDay == nil)
        #expect(AboutInfo(info: [:]).releaseDay == nil)
    }

    /// The app's own Info.plist carries the date release.sh writes.
    @Test func theAppHasAReleaseDate() {
        #expect(AboutInfo(info: Bundle.main.infoDictionary ?? [:]).releaseDay != nil)
    }

    /// The app menu's first item opens this window, not the standard panel,
    /// with Check for Updates still right under it.
    /// SwiftUI builds the menu in the system's language, not the app's.
    @Test func theAppMenuOpensTheAboutWindow() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let about = try #require(titles.firstIndex(of: String(localized: "About SignalBar")))
        #expect(titles[about + 1] == String(localized: "Check for Updates…"))
    }

    @Test func theWindowShowsAndComesBackAsOne() throws {
        AboutWindow.show()
        AboutWindow.show()
        let title = String(localized: "About SignalBar", bundle: AppLocale.bundle)
        let windows = NSApp.windows.filter { $0.isVisible && $0.title == title }
        #expect(windows.count == 1)
        windows.forEach { $0.close() }
    }
}
