import DKBMonitorCore
import SwiftUI

struct OverviewView: View {
    @Bindable private var viewModel = OverviewViewModel.shared
    @Bindable private var navigationState = AppNavigationState.shared
    @State private var navigationPath = NavigationPath()
    @State private var renamingGroup: String?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(selection: $viewModel.selection) {
                ForEach(viewModel.filteredGroups, id: \.group) { entry in
                    Section {
                        ForEach(entry.items) { overview in
                            TargetRowView(overview: overview, viewModel: viewModel) {
                                navigationPath.append(overview.id)
                            }
                            .tag(overview.id)
                            .draggable(TargetDragItem(id: overview.id))
                        }
                        .onMove { indices, newOffset in
                            viewModel.moveWithinGroup(entry.items, from: indices, to: newOffset)
                        }
                    } header: {
                        (Text(entry.group) + Text(" (\(entry.items.count))").foregroundStyle(.tertiary))
                            .contextMenu {
                                Button("Rename Group…") {
                                    renamingGroup = entry.group
                                    renameText = entry.group
                                }
                            }
                            .dropDestination(for: TargetDragItem.self) { items, _ in
                                for item in items { viewModel.moveToGroup(id: item.id, group: entry.group) }
                                return true
                            }
                    }
                }
            }
            // Zebra striping (alternatesRowBackgrounds) fills the List's
            // entire remaining height with bands sized to NSTableView's
            // default row height, which doesn't match this list's taller
            // custom TargetRowView content — the mismatch showed up as
            // undersized "empty" bands below the real rows. Plain .inset
            // keeps the same insets without that artifact.
            .listStyle(.inset)
            .navigationDestination(for: Int64.self) { targetId in
                TargetDetailView(targetId: targetId)
            }
            .toolbar {
                overviewToolbarContent
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: navigationState.pendingDetailTargetID) { _, newValue in
            guard let id = newValue else { return }
            navigationPath.append(id)
            navigationState.pendingDetailTargetID = nil
        }
        .sheet(isPresented: $viewModel.isPresentingAddSheet) {
            TargetFormView(mode: .add) { input in viewModel.addTarget(input) }
        }
        .sheet(item: $viewModel.editingTarget) { target in
            TargetFormView(mode: .edit(target)) { input in
                var updated = target
                updated.name = input.name
                updated.url = input.url
                updated.groupTag = input.groupTag
                updated.checkIntervalSecs = input.checkIntervalSecs
                updated.checkHTTP = input.checkHTTP
                updated.expectedStatus = input.expectedStatus
                updated.checkSSL = input.checkSSL
                updated.checkDomain = input.checkDomain
                updated.customPath = input.customPath
                updated.expectedBodyContains = input.expectedBodyContains
                viewModel.updateTarget(updated)
            }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Rename") {
                if let old = renamingGroup { viewModel.renameGroup(from: old, to: renameText) }
                renamingGroup = nil
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete Target?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteId != nil },
                set: { if !$0 { viewModel.pendingDeleteId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = viewModel.pendingDeleteId { viewModel.delete(id: id) }
                viewModel.pendingDeleteId = nil
            }
        } message: {
            Text("This permanently deletes this domain and its history. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete Selected Targets?",
            isPresented: $viewModel.isPresentingDeleteSelectedConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { viewModel.deleteSelected() }
        } message: {
            Text("This permanently deletes every selected domain and its history. This cannot be undone.")
        }
    }

    /// A real `.toolbar` (not a hand-drawn `HStack`) so these actions merge
    /// into the window's title bar chrome like any system app — this also
    /// picks up the Liquid Glass toolbar material automatically on macOS 26+
    /// without any extra styling on our part.
    @ToolbarContentBuilder
    private var overviewToolbarContent: some ToolbarContent {
        // No "N selected" label: on a Liquid Glass toolbar, macOS wraps
        // every item — plain text included — in the same pill-shaped
        // control chrome, so a text label ends up looking like a
        // non-functional button. Selection is already visible from the
        // highlighted rows, matching how Mail/Photos handle bulk-selection
        // toolbars (buttons only, no count label).
        if !viewModel.selection.isEmpty {
            ToolbarItemGroup(placement: .automatic) {
                Button("Enable") { viewModel.setEnabledForSelection(true) }
                Button("Disable") { viewModel.setEnabledForSelection(false) }
                Button(role: .destructive) { viewModel.isPresentingDeleteSelectedConfirm = true } label: { Text("Delete") }
            }
        }

        // `.navigation` pins this group to the toolbar's leading edge, right
        // next to the sidebar toggle — keeps Filter/Check All Now on the
        // left exactly as before, now that Add/Import-Export/Search have
        // moved to the trailing edge below.
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(TargetStatus.allCases, id: \.self) { status in
                    Toggle(status.localizedLabel, isOn: Binding(
                        get: { viewModel.statusFilters.contains(status) },
                        set: { isOn in
                            if isOn { viewModel.statusFilters.insert(status) } else { viewModel.statusFilters.remove(status) }
                        }
                    ))
                }
            } label: {
                Label(viewModel.statusFilters.isEmpty ? "All statuses" : "\(viewModel.statusFilters.count) filter(s)", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                viewModel.checkAllNow()
            } label: {
                if viewModel.isCheckingAll {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check All Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isCheckingAll)
        }

        // The actual push-to-the-right: a *flexible* spacer consumes all
        // the toolbar's remaining width at this exact point in the
        // sequence, shoving everything declared after it to the trailing
        // edge. `.navigation`/`.primaryAction` placements alone only
        // control which customizable "section" an item belongs to — they
        // don't add any gap between sections, which is why Import/Export,
        // Add, and Search were still rendering bunched up on the left next
        // to Filter/Check All Now before this was added. Pre-macOS 26 has
        // no flexible toolbar spacer API in SwiftUI, so this group still
        // renders left-packed there — same tradeoff already accepted for
        // the `ToolbarSpacer(.fixed, ...)` below.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }

        // `.primaryAction` pins this group to the toolbar's trailing edge —
        // Import/Export and Add Target now sit on the right, next to the
        // search field below, per the user's request to move these away
        // from the left-aligned Filter/Check All Now group.
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Export…") { viewModel.exportTargets() }
                Button("Import…") { viewModel.importTargets() }
            } label: {
                Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
            }

            // A plain, unstyled `Button` — same as Filter/Check All/
            // Import-Export above — so the system gives it the identical
            // native round toolbar-button chrome. Every previous attempt
            // that customized this button's style/background (`.plain` +
            // manual `Circle()`) stopped looking like a "real" toolbar
            // control to the system, so it got wrapped in the same generic
            // glass backing as the search field's raw `TextField` next to
            // it, and the two generic backings fused into one shape.
            Button {
                viewModel.isPresentingAddSheet = true
            } label: {
                Label("Add Target", systemImage: "plus")
            }
        }

        // Explicit boundary between the button group and the search field:
        // without it, macOS's Liquid Glass toolbar still merges the last
        // native button above with the search field's custom view into one
        // shared glass container, even though they're different
        // `ToolbarItemGroup`s. `ToolbarSpacer` (macOS 26+) is Apple's own
        // API for forcing a break in that grouping — on macOS <26 there's
        // no Liquid Glass merging to begin with, so it's simply a no-op gap.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // A real `NSSearchField` bridge instead of `.searchable`: that
        // modifier only works reliably when attached to the top-level
        // `NavigationSplitView` on macOS (nested `NavigationStack`s don't
        // render it at all), but attaching it there with a condition to
        // scope it to just this screen turned out to be unreliable — SwiftUI
        // doesn't consistently treat the if/else branches of a
        // conditionally-applied `.searchable` as the same view, so it kept
        // leaking onto Target Detail. A hand-rolled `TextField` avoided that
        // leak but never quite matched the system search field's bezel —
        // `NativeSearchField` is the actual control, so it matches exactly.
        ToolbarItem(placement: .primaryAction) {
            NativeSearchField(text: $viewModel.searchText, placeholder: "Search domains")
                .frame(minWidth: 200)
        }
    }
}
