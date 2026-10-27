import Foundation

/// In-app language override, independent of System Settings > Language &
/// Region — ports the same idea as MediaCatch's `AppLocale`/
/// `LocalizationCenter` (`native/MediaCatchApp/App/Localization.swift`).
/// Unlike Downloader's approach (a manual `t(key)` lookup against a
/// hand-picked `.lproj` bundle, needed there because its Settings view builds
/// `Text` from plain `String`s), this app's views already use
/// `LocalizedStringKey` almost everywhere — SwiftUI resolves those against
/// whatever `Locale` sits in the environment, so overriding
/// `\.locale` on the app's root views (see `SignalBarApp.swift`) is enough
/// to make the switch actually take effect, without a custom lookup helper.
enum AppLocale: String, CaseIterable, Identifiable {
    case en, vi

    var id: Self { self }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Falls back to the system's language exactly once, on first launch,
    /// before the user has picked anything in Settings.
    static var systemDefault: AppLocale {
        Locale.current.language.languageCode?.identifier == "vi" ? .vi : .en
    }

    /// The language picked in Settings. Same key as the
    /// `@AppStorage("languagePreference")` there.
    static var selected: AppLocale {
        UserDefaults.standard.string(forKey: "languagePreference").flatMap(AppLocale.init(rawValue:)) ?? systemDefault
    }

    /// The `.lproj` bundle of the in-app language, for `String(localized:bundle:)`
    /// (same as KeyCellar). Text built as a `String` outside SwiftUI, such as
    /// notifications and webhook posts, never sees the `\.locale` override, and
    /// `String(localized:)` alone reads the *system* language. There is no
    /// `en.lproj` (English is the source language), so for English this falls
    /// back to the main bundle, which follows the system language: callers that
    /// need English regardless check `selected` first.
    static var bundle: Bundle {
        Bundle.main.path(forResource: selected.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
