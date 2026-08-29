import DKBMonitorCore
import SwiftUI

struct OverviewView: View {
    @Bindable private var viewModel = OverviewViewModel.shared
    @State private var renamingGroup: String?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            List(selection: $viewModel.selection) {
                ForEach(viewModel.filteredGroups, id: \.group) { entry in
                    Section {
                        ForEach(entry.items) { overview in
                            TargetRowView(overview: overview, viewModel: viewModel)
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
            .listStyle(.inset)
        }
        .searchable(text: $viewModel.searchText, prompt: "Search domains")
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
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

    private var toolbar: some View {
        HStack {
            Menu {
                ForEach(TargetStatus.allCases, id: \.self) { status in
                    Toggle(status.label, isOn: Binding(
                        get: { viewModel.statusFilters.contains(status) },
                        set: { isOn in
                            if isOn { viewModel.statusFilters.insert(status) } else { viewModel.statusFilters.remove(status) }
                        }
                    ))
                }
            } label: {
                Label(viewModel.statusFilters.isEmpty ? "All statuses" : "\(viewModel.statusFilters.count) filter(s)", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if !viewModel.selection.isEmpty {
                Text("\(viewModel.selection.count) selected")
                    .foregroundStyle(.secondary)
                Button("Enable") { viewModel.setEnabledForSelection(true) }
                Button("Disable") { viewModel.setEnabledForSelection(false) }
                Button(role: .destructive) { viewModel.deleteSelected() } label: { Text("Delete") }
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
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                viewModel.isPresentingAddSheet = true
            } label: {
                Label("Add Target", systemImage: "plus")
            }
        }
        .padding(8)
    }
}
