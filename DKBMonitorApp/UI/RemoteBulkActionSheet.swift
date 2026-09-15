import DKBMonitorCore
import SwiftUI

struct RemoteBulkActionSheet: View {
    let servers: [RemoteServer]

    @State private var viewModel = RemoteBulkActionViewModel(
        repo: AppDatabase.shared.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    )
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run on Multiple Servers")
                .font(.title3.weight(.semibold))

            actionPicker
            Divider()
            serverPicker

            if !viewModel.outcomes.isEmpty {
                Divider()
                results
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear { viewModel.load(servers: servers) }
        .confirmationDialog(
            "Run this on \(viewModel.selectedIds.count) server(s)?",
            isPresented: $viewModel.isPresentingConfirm,
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) { Task { await viewModel.run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes state on every selected server.")
        }
    }

    private var actionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Action", selection: $viewModel.kind) {
                ForEach(RemoteBulkActionViewModel.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            if viewModel.kind.needsServiceName {
                if viewModel.knownServiceNames.isEmpty {
                    // Nothing allowlisted anywhere means the run cannot
                    // succeed on any server, so say that here rather than
                    // letting every row come back refused.
                    Label(
                        "No service is allowlisted on any of these servers. Add one in a server's settings first.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Picker("Service", selection: $viewModel.serviceName) {
                        ForEach(viewModel.knownServiceNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }
        }
    }

    private var serverPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Servers").font(.headline)
                Spacer()
                Button("Select All") { viewModel.selectAll() }
                    .buttonStyle(.link)
                Button("None") { viewModel.clearSelection() }
                    .buttonStyle(.link)
            }
            List {
                ForEach(viewModel.servers) { server in
                    Toggle(isOn: Binding(
                        get: { server.id.map { viewModel.selectedIds.contains($0) } ?? false },
                        set: { _ in viewModel.toggle(server) }
                    )) {
                        HStack(spacing: 6) {
                            Text(server.name)
                            Text("\(server.username)@\(server.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 160)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results").font(.headline)
            // Every server gets a row whatever happened to it: a run where
            // half the fleet was unreachable must not look like a run where
            // half the fleet was never asked.
            Table(viewModel.outcomes) {
                TableColumn("Server") { Text($0.serverName) }
                TableColumn("Result") { outcome in
                    if outcome.succeeded {
                        Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                TableColumn("Detail") { Text($0.summary).lineLimit(2) }
            }
            .frame(minHeight: 120)
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.isRunning {
                ProgressView().controlSize(.small)
                Text("Running on \(viewModel.selectedIds.count) server(s)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
            Button("Run") { viewModel.runRequested() }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canRun)
        }
    }
}
