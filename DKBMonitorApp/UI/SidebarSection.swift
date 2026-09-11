import SwiftUI

/// Top-level sidebar sections. Settings is one tab among these — opening it
/// from the app menu (Cmd+,) or the menu bar extra both route into this same
/// in-window tab via `WindowPresenter.showSettings()` rather than a separate
/// `Settings {}` scene/window, per the user's request for a single unified
/// Settings surface.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case domains, remoteServers, system, settings

    var id: Self { self }

    /// `LocalizedStringKey` (not `String`) so Xcode's String Catalog
    /// extraction picks it up (Phase 13) — `Label(_:systemImage:)` only
    /// looks up the catalog for the `LocalizedStringKey`-typed overload.
    var title: LocalizedStringKey {
        switch self {
        case .domains: "Domains"
        case .remoteServers: "Server Manager"
        case .system: "System"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .domains: "network"
        case .remoteServers: "server.rack"
        case .system: "cpu"
        case .settings: "gearshape"
        }
    }
}
