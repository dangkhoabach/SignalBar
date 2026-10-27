import Foundation

/// The one place that decides how a tagged list is split into sections and
/// what order those sections come in.
///
/// Both list panes group by an optional `groupTag` and both put untagged
/// rows last, but they had grown two separate copies of that rule —
/// `OverviewViewModel.filteredGroups` honouring a saved drag order,
/// `RemoteServerListViewModel.groupedServers` purely alphabetical. Two
/// copies of one rule is how the Domains list and the Servers list end up
/// sorting differently after someone fixes only the copy they were looking
/// at. `preferredOrder` is what lets a single implementation serve both:
/// the Overview passes its saved order, the server list passes nothing.
enum TagGrouping {
    /// Shown as the section title for rows with no tag, and reserved: a
    /// group a user literally names "Ungrouped" merges into that section
    /// rather than producing two sections with the same heading.
    static let ungroupedLabel = "Ungrouped"

    /// Sections in `preferredOrder` first (skipping any that no row uses),
    /// then every other tag alphabetically, then untagged rows last.
    ///
    /// Untagged always sits at the bottom regardless of `preferredOrder`,
    /// because it isn't a group the user arranged — it's where rows land
    /// when they haven't been arranged at all.
    static func groups<Item>(
        _ items: [Item],
        preferredOrder: [String] = [],
        tag: (Item) -> String?
    ) -> [(group: String, items: [Item])] {
        let buckets = Dictionary(grouping: items) { tag($0) ?? ungroupedLabel }

        var names = preferredOrder.filter { $0 != ungroupedLabel && buckets[$0] != nil }
        let placed = Set(names)
        names += buckets.keys
            .filter { !placed.contains($0) && $0 != ungroupedLabel }
            .sorted()
        if buckets[ungroupedLabel] != nil { names.append(ungroupedLabel) }

        return names.map { (group: $0, items: buckets[$0] ?? []) }
    }
}
