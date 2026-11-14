import SwiftUI

/// Top-level sidebar sections. Settings is one tab among these — opening it
/// from the app menu (Cmd+,) or the menu bar extra both route into this same
/// in-window tab via `WindowPresenter.showSettings()` rather than a separate
/// `Settings {}` scene/window, per the user's request for a single unified
/// Settings surface.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case domains, remoteServers, networkDevices, networkAddresses, networks, settings

    var id: Self { self }

    /// `LocalizedStringKey` (not `String`) so Xcode's String Catalog
    /// extraction picks it up — `Label(_:systemImage:)` only
    /// looks up the catalog for the `LocalizedStringKey`-typed overload.
    var title: LocalizedStringKey {
        switch self {
        case .domains: "Domains"
        case .remoteServers: "Server Manager"
        case .networkDevices: "Devices"
        case .networkAddresses: "IP Addresses"
        case .networks: "Networks"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .domains: "network"
        case .remoteServers: "server.rack"
        case .networkDevices: "laptopcomputer.and.iphone"
        case .networkAddresses: "number"
        case .networks: "point.3.filled.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}
