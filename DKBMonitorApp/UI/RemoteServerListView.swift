import DKBMonitorCore
import SwiftUI

struct RemoteServerListView: View {
    @Bindable private var viewModel = RemoteServerListViewModel.shared

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.servers.isEmpty {
                    ContentUnavailableView(
                        "No Remote Servers",
                        systemImage: "server.rack",
                        description: Text("Add a server to manage nginx, systemd services, logs, and stats over SSH.")
                    )
                } else {
                    List {
                        ForEach(viewModel.servers) { server in
                            RemoteServerRowView(
                                server: server,
                                isTesting: server.id.map { viewModel.testingServerIds.contains($0) } ?? false,
                                resultMessage: server.id.flatMap { viewModel.testResultMessages[$0] },
                                onTest: { viewModel.testConnection(server) },
                                onEdit: { viewModel.editingServer = server },
                                onDelete: { viewModel.pendingDeleteId = server.id }
                            )
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Remote Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.isPresentingAddSheet = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear { viewModel.load() }
        .sheet(isPresented: $viewModel.isPresentingAddSheet) {
            RemoteServerFormView(mode: .add, onSave: { viewModel.addServer($0) })
        }
        .sheet(item: $viewModel.editingServer) { server in
            RemoteServerFormView(
                mode: .edit(server),
                onUpdate: { updated, newCredential in viewModel.updateServer(updated, newCredential: newCredential) }
            )
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this server?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteId != nil },
                set: { if !$0 { viewModel.pendingDeleteId = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = viewModel.pendingDeleteId { viewModel.delete(id: id) }
                viewModel.pendingDeleteId = nil
            }
            Button("Cancel", role: .cancel) { viewModel.pendingDeleteId = nil }
        } message: {
            Text("This removes the server and its stored credential from Keychain. This can't be undone.")
        }
    }
}

private struct RemoteServerRowView: View {
    let server: RemoteServer
    let isTesting: Bool
    let resultMessage: String?
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.headline)
                    Text("\(server.username)@\(server.host):\(String(server.port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if server.hostKeyFingerprint != nil {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                        .help("Host key pinned")
                }
                Button {
                    onTest()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(isTesting)
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(resultMessage.hasPrefix("Connected") ? .green : .red)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
