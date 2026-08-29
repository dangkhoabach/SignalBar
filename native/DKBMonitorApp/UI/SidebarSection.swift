import SwiftUI

/// Top-level sidebar sections. Settings is deliberately not one of these —
/// per Phase 12's exit criteria it uses the native `Settings {}` scene
/// (Cmd+,) instead, the standard macOS idiom, superseding Phase 11's initial
/// 3-item sidebar wording.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case domains, system

    var id: Self { self }

    /// `LocalizedStringKey` (not `String`) so Xcode's String Catalog
    /// extraction picks it up (Phase 13) — `Label(_:systemImage:)` only
    /// looks up the catalog for the `LocalizedStringKey`-typed overload.
    var title: LocalizedStringKey {
        switch self {
        case .domains: "Domains"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .domains: "network"
        case .system: "cpu"
        }
    }
}
