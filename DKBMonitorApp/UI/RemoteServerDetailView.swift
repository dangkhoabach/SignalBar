import DKBMonitorCore
import SwiftUI

/// `DetailTab` is deliberately a segmented-tab enum (not a fixed 2-section
/// layout) so Phase 2/3/4 can add `.nginx`/`.logs`/`.stats` cases here
/// without restructuring the view — see docs/remote-server-management-plan.md
/// §3's 4-tab design.
private enum DetailTab: String, CaseIterable, Identifiable {
    case services = "Services"
    case nginx = "Nginx"
    case logs = "Logs"
    case stats = "Stats"
    case activityLog = "Activity Log"
    var id: Self { self }
}

struct RemoteServerDetailView: View {
    let serverId: Int64

    @State private var viewModel = RemoteServerDetailViewModel(
        repo: AppDatabase.shared.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    )
    @State private var selectedTab: DetailTab = .services

    var body: some View {
        Group {
            if let server = viewModel.server {
                VStack(spacing: 0) {
                    Picker("", selection: $selectedTab) {
                        ForEach(DetailTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    switch selectedTab {
                    case .services:
                        servicesTab(server)
                    case .nginx:
                        nginxTab(server)
                    case .logs:
                        logsTab(server)
                    case .stats:
                        statsTab
                    case .activityLog:
                        activityLogTab
                    }
                }
                .navigationTitle(server.name)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { viewModel.load(serverId: serverId) }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            viewModel.pendingAction?.confirmationMessage ?? "",
            isPresented: Binding(
                get: { viewModel.pendingAction != nil },
                set: { if !$0 { viewModel.pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm", role: .destructive) { viewModel.confirmPendingAction() }
            Button("Cancel", role: .cancel) { viewModel.pendingAction = nil }
        }
    }

    // MARK: - Services tab

    @ViewBuilder
    private func servicesTab(_ server: RemoteServer) -> some View {
        List {
            Section("Allowlisted services") {
                if viewModel.allowlistedServices.isEmpty {
                    Text("No services yet — add one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.allowlistedServices) { entry in
                    serviceRow(entry)
                }
            }
            Section("Add service") {
                HStack {
                    TextField("Service name", text: $viewModel.newServiceName, prompt: Text("nginx"))
                        .onSubmit { viewModel.addServiceToAllowlist() }
                    Button("Add") { viewModel.addServiceToAllowlist() }
                        .disabled(viewModel.newServiceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func serviceRow(_ entry: RemoteAllowlistEntry) -> some View {
        let name = entry.value
        let statusKey = "status:\(name)"
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.monospaced())
                if let status = viewModel.serviceStatuses[name] {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "active" ? .green : .secondary)
                } else {
                    Text("Unknown — tap Refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if viewModel.isRunning(statusKey) {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh") { viewModel.refreshStatus(name) }
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("Start") { viewModel.pendingAction = .serviceStart(name: name) }
                Button("Stop", role: .destructive) { viewModel.pendingAction = .serviceStop(name: name) }
                Button("Restart") { viewModel.pendingAction = .serviceRestart(name: name) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .swipeActions {
            Button("Remove", role: .destructive) { viewModel.removeServiceFromAllowlist(entry) }
        }
    }

    // MARK: - Nginx tab

    @ViewBuilder
    private func nginxTab(_ server: RemoteServer) -> some View {
        HStack(spacing: 0) {
            List {
                Section("Config files") {
                    if viewModel.allowlistedConfigPaths.isEmpty {
                        Text("No paths yet — add one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.allowlistedConfigPaths) { entry in
                        Text(entry.value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(entry.value == viewModel.openConfigPath ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.openConfig(entry.value) }
                            .swipeActions {
                                Button("Remove", role: .destructive) { viewModel.removeConfigPathFromAllowlist(entry) }
                            }
                    }
                }
                Section("Add path") {
                    TextField("Path", text: $viewModel.newConfigPath, prompt: Text("/etc/nginx/sites-available/default"))
                        .font(.caption)
                        .onSubmit { viewModel.addConfigPathToAllowlist() }
                    Button("Add") { viewModel.addConfigPathToAllowlist() }
                        .disabled(viewModel.newConfigPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listStyle(.inset)
            .frame(width: 240)

            Divider()

            configEditor
        }
    }

    @ViewBuilder
    private var configEditor: some View {
        if let path = viewModel.openConfigPath {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test config") { viewModel.runNginxTest() }
                        .disabled(viewModel.isRunning(RemoteAction.nginxTest.logName))
                    Button("Save") { viewModel.saveConfig() }
                        .disabled(viewModel.isRunning("writeFile(\(path))"))
                    Button("Reload nginx") { viewModel.requestReload() }
                        .disabled(viewModel.nginxTestPassed != true)
                        .help(
                            viewModel.nginxTestPassed == true
                                ? "Apply this config now"
                                : "Run \"Test config\" successfully first"
                        )
                }
                .padding(8)

                if viewModel.isLoadingConfig {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $viewModel.configEditorText)
                        .font(.system(.body, design: .monospaced))
                        .padding(4)
                }

                if let output = viewModel.nginxTestOutput {
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: viewModel.nginxTestPassed == true ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(viewModel.nginxTestPassed == true ? .green : .red)
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Config File",
                systemImage: "doc.text",
                description: Text("Pick a path on the left to view and edit it.")
            )
        }
    }

    // MARK: - Logs tab

    @ViewBuilder
    private func logsTab(_ server: RemoteServer) -> some View {
        HStack(spacing: 0) {
            List {
                Section("Log files") {
                    if viewModel.allowlistedLogPaths.isEmpty {
                        Text("No paths yet — add one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.allowlistedLogPaths) { entry in
                        Text(entry.value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(entry.value == viewModel.selectedLogPath ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectLogPath(entry.value) }
                            .swipeActions {
                                Button("Remove", role: .destructive) { viewModel.removeLogPathFromAllowlist(entry) }
                            }
                    }
                }
                Section("Add path") {
                    TextField("Path", text: $viewModel.newLogPath, prompt: Text("/var/log/nginx/error.log"))
                        .font(.caption)
                        .onSubmit { viewModel.addLogPathToAllowlist() }
                    Button("Add") { viewModel.addLogPathToAllowlist() }
                        .disabled(viewModel.newLogPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listStyle(.inset)
            .frame(width: 240)

            Divider()

            logViewer
        }
    }

    @ViewBuilder
    private var logViewer: some View {
        if let path = viewModel.selectedLogPath {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Lines", selection: $viewModel.logLineCount) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("500").tag(500)
                    }
                    .frame(width: 100)
                    .onChange(of: viewModel.logLineCount) { _, _ in viewModel.refreshLog() }
                    if viewModel.isRunning(RemoteAction.tailLog(path: path, lines: viewModel.logLineCount).logName) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { viewModel.refreshLog() }
                    }
                }
                .padding(8)
                Divider()
                ScrollView {
                    Text(viewModel.logOutput.isEmpty ? "No output yet." : viewModel.logOutput)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Log File",
                systemImage: "doc.plaintext",
                description: Text("Pick a path on the left to tail its last lines.")
            )
        }
    }

    // MARK: - Stats tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Resource Stats").font(.headline)
                    Spacer()
                    if viewModel.isRunning(RemoteServerDetailViewModel.statsKey) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { viewModel.refreshStats() }
                    }
                }

                if let error = viewModel.statsErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statTile(title: "Disk (/)", value: diskSummary)
                    statTile(title: "Memory", value: memorySummary)
                    statTile(title: "Load Average", value: loadSummary)
                    statTile(title: "Uptime", value: viewModel.uptime?.raw ?? "—")
                }

                if viewModel.diskUsage == nil && viewModel.memoryUsage == nil && viewModel.uptime == nil {
                    ContentUnavailableView(
                        "No Stats Yet",
                        systemImage: "gauge",
                        description: Text("Tap Refresh to fetch disk, memory, load, and uptime.")
                    )
                }
            }
            .padding()
        }
    }

    private var diskSummary: String {
        guard let disk = viewModel.diskUsage else { return "—" }
        return "\(disk.used) / \(disk.size) (\(disk.usePercent))"
    }

    private var memorySummary: String {
        guard let mem = viewModel.memoryUsage else { return "—" }
        return "\(mem.usedMB) MB / \(mem.totalMB) MB"
    }

    private var loadSummary: String {
        guard let uptime = viewModel.uptime, !uptime.loadAverages.isEmpty else { return "—" }
        return uptime.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    @ViewBuilder
    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Activity log tab

    private var activityLogTab: some View {
        List(viewModel.commandLog) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.action).font(.body.monospaced())
                    Spacer()
                    Text(entry.executedAt, style: .relative).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: entry.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(entry.exitCode == 0 ? .green : .red)
                    if let excerpt = entry.outputExcerpt, !excerpt.isEmpty {
                        Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.commandLog.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock")
            }
        }
    }
}
