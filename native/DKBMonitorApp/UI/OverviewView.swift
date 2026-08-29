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
                        Text(entry.group)
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
            .listStyle(.inset(alternatesRowBackgrounds: true))
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
    }

    /// A real `.toolbar` (not a hand-drawn `HStack`) so these actions merge
    /// into the window's title bar chrome like any system app — this also
    /// picks up the Liquid Glass toolbar material automatically on macOS 26+
    /// without any extra styling on our part.
    @ToolbarContentBuilder
    private var overviewToolbarContent: some ToolbarContent {
        // Kept as its own `ToolbarItem` rather than inside the button group
        // below: macOS visually fuses adjacent `Button`s in a
        // `ToolbarItemGroup` into one pill-shaped cluster, and a plain
        // `Text` swept into that same group gets dragged into the pill's
        // background too, which looks broken since it isn't a button.
        if !viewModel.selection.isEmpty {
            ToolbarItem(placement: .automatic) {
                Text("\(viewModel.selection.count) selected")
                    .foregroundStyle(.secondary)
            }
            ToolbarItemGroup(placement: .automatic) {
                Button("Enable") { viewModel.setEnabledForSelection(true) }
                Button("Disable") { viewModel.setEnabledForSelection(false) }
                Button(role: .destructive) { viewModel.deleteSelected() } label: { Text("Delete") }
            }
        }

        ToolbarItemGroup(placement: .automatic) {
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
                Label("Check All Now", systemImage: "arrow.clockwise")
            }

            Menu {
                Button("Export…") { viewModel.exportTargets() }
                Button("Import…") { viewModel.importTargets() }
            } label: {
                Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
            }

            Button {
                viewModel.isPresentingAddSheet = true
            } label: {
                Label("Add Target", systemImage: "plus")
            }
        }
    }
}
