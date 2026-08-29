/// The 3 top-level sections per Mục 3's spec. `.system`/`.settings` are
/// placeholders until Phase 12 fills them in.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case domains, system, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .domains: "Domains"
        case .system: "System"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .domains: "network"
        case .system: "cpu"
        case .settings: "gearshape"
        }
    }
}
