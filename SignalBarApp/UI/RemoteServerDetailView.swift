import SignalBarCore
import SwiftUI

/// `DetailTab` is deliberately a segmented-tab enum (not a fixed 2-section
/// layout) so the `.nginx`/`.logs`/`.stats` cases could be added without
/// restructuring the view.
private enum DetailTab: String, CaseIterable, Identifiable {
    case stats = "Stats"
    case services = "Services"
    case nginx = "Nginx"
    case logs = "Logs"
    case activityLog = "Activity Log"
    var id: Self { self }
}

struct RemoteServerDetailView: View {
    let serverId: Int64

    @State private var viewModel = RemoteServerDetailViewModel(
        repo: AppDatabase.shared.map { RemoteServerRepository(dbQueue: $0.dbQueue) }
    )
    @State private var selectedTab: DetailTab = .stats

    var body: some View {
        Group {
            if let server = viewModel.server {
                Group {
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
                // `.principal` (rather than embedding the Picker in the body,
                // as before) is what gets a segmented control the native
                // Liquid Glass toolbar pill on macOS 26+, matching the rest
                // of the app's toolbar-hosted controls instead of a flat
                // in-body segmented bar.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // See CleanupView's copy of this: the empty label still
                        // claims layout space without `.labelsHidden()`, and the
                        // fixed 480pt width squeezed the five segments unevenly.
                        Picker("", selection: $selectedTab) {
                            ForEach(DetailTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } else {
                detailSkeleton
            }
        }
        .onAppear {
            viewModel.load(serverId: serverId)
            // Stats is now the default tab (first tab the user sees), so
            // this covers arriving on it directly — `onChange` below only
            // fires on a later *switch* into the tab, not this initial
            // state.
            fetchStatsIfNeededOnFirstVisit(to: selectedTab)
        }
        .onChange(of: selectedTab) { _, newTab in
            // Auto-fetch on first visit to the Stats tab, instead of making
            // the user hit Refresh once just to see anything — subsequent
            // visits still rely on the manual Refresh button (no auto-poll,
            // by design).
            fetchStatsIfNeededOnFirstVisit(to: newTab)
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

    private func fetchStatsIfNeededOnFirstVisit(to tab: DetailTab) {
        guard tab == .stats, viewModel.diskUsage == nil, viewModel.memoryUsage == nil, viewModel.uptime == nil else { return }
        viewModel.refreshStats()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // Also gated on `isLoadingConfig` — without it, saving
                    // while the editor is still mid-fetch would overwrite
                    // the real file with the empty/stale placeholder text
                    // `configEditorText` holds until the read completes.
                    Button("Save") { viewModel.saveConfig() }
                        .disabled(viewModel.isLoadingConfig || viewModel.isRunning("writeFile(\(path))"))
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
                    configSkeleton
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Config File",
                systemImage: "doc.text",
                description: Text("Pick a path on the left to view and edit it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Log File",
                systemImage: "doc.plaintext",
                description: Text("Pick a path on the left to tail its last lines.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Stats tab

    /// Card layout ported from `SystemView`'s own cards (`GroupBox` +
    /// `Label` header + trailing value + `StatBar`) so the local-machine and
    /// remote-server stats pages read as the same design language instead of
    /// two unrelated styles.
    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resource Stats").font(.headline)
                        if let osInfo = viewModel.osInfo {
                            Text([osInfo.prettyName, osInfo.kernel].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if viewModel.isRunning(RemoteServerDetailViewModel.statsKey) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { viewModel.refreshStats() }
                    }
                }
                Text("Numbers are a snapshot from the last refresh — tap Refresh to update them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = viewModel.statsErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                if statsLoaded {
                    statsGrid
                } else if viewModel.isRunning(RemoteServerDetailViewModel.statsKey) {
                    statsGrid.redacted(reason: .placeholder)
                } else {
                    ContentUnavailableView(
                        "No Stats Yet",
                        systemImage: "gauge",
                        description: Text("Tap Refresh to fetch CPU, disk, memory, and uptime.")
                    )
                }
            }
            .padding()
        }
    }

    private var statsLoaded: Bool {
        viewModel.diskUsage != nil || viewModel.memoryUsage != nil || viewModel.uptime != nil || viewModel.cpuUsage != nil
    }

    private var statsGrid: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                cpuStatCard
                diskStatCard
            }
            HStack(alignment: .top, spacing: 12) {
                memoryStatCard
                loadAverageStatCard
            }
            HStack(alignment: .top, spacing: 12) {
                uptimeStatCard
                Color.clear
            }
        }
    }

    private var diskPercent: Double {
        guard let disk = viewModel.diskUsage else { return 0 }
        return Double(disk.usePercent.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
    }

    private var memoryPercent: Double {
        guard let mem = viewModel.memoryUsage, mem.totalMB > 0 else { return 0 }
        return Double(mem.usedMB) / Double(mem.totalMB) * 100
    }

    private var swapPercent: Double {
        guard let mem = viewModel.memoryUsage, let total = mem.swapTotalMB, let used = mem.swapUsedMB, total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    private var cpuStatCard: some View {
        statCard(title: "CPU", systemImage: "cpu", trailingText: viewModel.cpuUsage.map { "\(Int($0.busyPercent.rounded()))%" }) {
            StatBar(percent: viewModel.cpuUsage?.busyPercent ?? 0, color: statBarColor(viewModel.cpuUsage?.busyPercent ?? 0))
            // I/O wait is idle time, so it stays out of the bar — but a high
            // figure with a low load average is a stuck kernel counter, and
            // hiding it would hide the one clue that says so.
            if let ioWait = viewModel.cpuUsage?.ioWaitPercent, ioWait >= 1 {
                Text("I/O wait \(Int(ioWait.rounded()))%")
                    .font(.caption)
                    .foregroundStyle(ioWait >= 50 ? .orange : .secondary)
            }
        }
    }

    private var diskStatCard: some View {
        statCard(title: "Disk (/)", systemImage: "internaldrive", trailingText: viewModel.diskUsage?.usePercent) {
            StatBar(percent: diskPercent, color: statBarColor(diskPercent))
            Text(viewModel.diskUsage.map { "\($0.used) used of \($0.size)" } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryStatCard: some View {
        statCard(title: "Memory", systemImage: "memorychip", trailingText: viewModel.memoryUsage.map { _ in "\(Int(memoryPercent.rounded()))%" }) {
            StatBar(percent: memoryPercent, color: statBarColor(memoryPercent))
            Text(viewModel.memoryUsage.map { "\($0.usedMB) MB used of \($0.totalMB) MB" } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let mem = viewModel.memoryUsage, let swapTotal = mem.swapTotalMB, swapTotal > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Swap").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(mem.swapUsedMB ?? 0) MB / \(swapTotal) MB").font(.caption).foregroundStyle(.secondary)
                    }
                    StatBar(percent: swapPercent, color: statBarColor(swapPercent))
                }
            }
        }
    }

    private var loadAverageStatCard: some View {
        statCard(title: "Load Average", systemImage: "gauge.with.dots.needle.50percent", trailingText: nil) {
            if let uptime = viewModel.uptime, !uptime.loadAverages.isEmpty {
                Text(uptime.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: "  ·  "))
                    .font(.title3.monospacedDigit())
            } else {
                Text("—").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var uptimeStatCard: some View {
        statCard(title: "Uptime", systemImage: "clock", trailingText: nil) {
            Text(viewModel.uptime?.raw ?? "—")
                .font(.title3.monospacedDigit())
                .lineLimit(2)
        }
    }

    private func statBarColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .blue
    }

    @ViewBuilder
    private func statCard<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        trailingText: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text(title).font(.subheadline.weight(.medium))
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    if let trailingText {
                        Text(trailingText).font(.subheadline.weight(.semibold))
                    }
                }
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Activity log tab

    private var activityLogTab: some View {
        List(viewModel.commandLog) { entry in
            activityLogRow(entry)
                .listRowSeparator(.hidden)
                .padding(.vertical, 4)
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.commandLog.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock")
            }
        }
    }

    /// Card-style row (icon + colored status pill + excerpt in its own
    /// shaded block) replacing the old plain-text three-line layout, which
    /// buried the pass/fail signal in a small inline icon and ran the
    /// excerpt directly against the row background — hard to scan when
    /// several entries in a row failed.
    private func activityLogRow(_ entry: RemoteCommandLogEntry) -> some View {
        let succeeded = entry.exitCode == 0
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(succeeded ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.action)
                        .font(.body.monospaced().weight(.medium))
                    Spacer()
                    Text(entry.executedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let excerpt = entry.outputExcerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Skeletons

    /// Shown while `RemoteServerDetailViewModel.load(serverId:)`'s
    /// synchronous DB read is in flight (near-instant in practice, but a
    /// shaped skeleton still reads better than a bare spinner) — mirrors
    /// `TargetDetailView`'s skeleton pattern.
    private var detailSkeleton: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1) // keeps the toolbar picker's space stable
            List {
                Section("Loading") {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack {
                            Text("service-name").font(.body.monospaced())
                            Spacer()
                            Text("active").font(.caption)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .redacted(reason: .placeholder)
    }

    /// Placeholder lines shown while a config file is being fetched over
    /// SFTP, in place of a plain centered spinner — varied widths read more
    /// like "text is coming" than a uniform block would.
    private var configSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: index.isMultiple(of: 3) ? 160 : 320, height: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .redacted(reason: .placeholder)
    }
}

/// Thin horizontal progress bar — copy of `SystemView`'s private `StatBar`
/// (file-scoped there, so it can't be reused directly) kept intentionally
/// tiny rather than promoted to a shared file for one more caller.
private struct StatBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: height)
    }
}
