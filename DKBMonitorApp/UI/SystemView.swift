import Charts
import DKBMonitorCore
import SwiftUI

/// Ported layout from the old Tauri app's `src/pages/System.tsx`: a 2-column
/// grid of cards, each combining related metrics (Swap nested under Memory,
/// fan RPMs nested under Temperature) rather than one metric per card, with
/// color-coded progress bars and per-core CPU usage — richer than the
/// original SwiftUI-only redesign, which the user found too sparse next to
/// the app it's replacing. Laid out as `HStack`-paired rows (see
/// `cardPairs`) rather than `LazyVGrid`, so each row's height matches its
/// own tallest card instead of either leaving every short card badly
/// mismatched or forcing one fixed height on every card in the page.
private enum ProcessSortKey {
    case name, status, cpu, memory
}

struct SystemView: View {
    @Bindable private var viewModel = SystemViewModel.shared
    @State private var processSearchText = ""
    @State private var processSortKey: ProcessSortKey = .cpu
    @State private var processSortAscending = false

    private var stats: SystemStats { viewModel.current }

    private static let gridSpacing: CGFloat = 18
    private static let outerPadding: CGFloat = 24
    private static let sparklineHeight: CGFloat = 32
    private static let statusColumnWidth: CGFloat = 90
    private static let cpuColumnWidth: CGFloat = 56
    private static let memoryColumnWidth: CGFloat = 150

    private var ramPercent: Double {
        stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
    }

    private var swapPercent: Double {
        stats.swapTotalMB > 0 ? Double(stats.swapUsedMB) / Double(stats.swapTotalMB) * 100 : 0
    }

    private var diskPercent: Double {
        stats.diskTotalGB > 0 ? stats.diskUsedGB / stats.diskTotalGB * 100 : 0
    }

    var body: some View {
        ScrollView {
            if viewModel.hasLoadedOnce {
                VStack(spacing: Self.gridSpacing) {
                    ForEach(Array(cardPairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            pair.0
                            if let second = pair.1 {
                                second
                            } else {
                                Color.clear
                            }
                        }
                    }
                    processesCard
                }
                .padding(Self.outerPadding)
            } else {
                skeletonGrid
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .toolbar {
            // A real window-toolbar search field (same `NativeSearchField`
            // bridge `OverviewView` uses), not one embedded in the card's
            // own body — a `TextField`/`NSSearchField` sitting inside a
            // plain `GroupBox` never gets the Liquid Glass material macOS 26
            // gives genuine toolbar items, so it looked visually
            // inconsistent with Domains' search box. Placing it here fixes
            // that by construction: it's the same kind of toolbar item.
            ToolbarItem(placement: .primaryAction) {
                NativeSearchField(text: $processSearchText, placeholder: "Filter apps")
                    .frame(minWidth: 200)
            }
        }
    }

    /// Pairs of cards laid out with `HStack`, not `LazyVGrid` — an `HStack`
    /// gives every child the same proposed height (the row's tallest
    /// natural content), so a short card (Storage) and a tall one
    /// (Network) sharing a row end up visually equal-height *for that row*,
    /// while a different row (e.g. CPU/Temperature, both naturally tall) is
    /// free to be taller overall. `LazyVGrid` never did this — each cell
    /// sized independently — and forcing one fixed height across every card
    /// regardless of row (an earlier attempt) just turned simple cards like
    /// Storage/Uptime into mostly-empty boxes.
    private var cardPairs: [(AnyView, AnyView?)] {
        var cards: [AnyView] = [AnyView(cpuCard), AnyView(temperatureCard)]
        if stats.gpuName != nil { cards.append(AnyView(gpuCard)) }
        cards.append(AnyView(memoryCard))
        cards.append(AnyView(diskCard))
        cards.append(AnyView(networkCard))
        if let battery = stats.batteryPercent { cards.append(AnyView(batteryCard(percent: battery))) }
        cards.append(AnyView(uptimeCard))

        var pairs: [(AnyView, AnyView?)] = []
        var index = 0
        while index < cards.count {
            let second = index + 1 < cards.count ? cards[index + 1] : nil
            pairs.append((cards[index], second))
            index += 2
        }
        return pairs
    }

    private var skeletonGrid: some View {
        let placeholder = AnyView(
            card(title: "Loading", systemImage: "circle.dashed", trailingText: "00%") {
                StatBar(percent: 0, color: .blue)
            }
        )
        return VStack(spacing: Self.gridSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    placeholder
                    placeholder
                }
            }
            processesCard
        }
        .padding(Self.outerPadding)
        .redacted(reason: .placeholder)
    }

    // MARK: - Cards

    private var cpuCard: some View {
        card(title: "CPU", systemImage: "cpu", trailingText: "\(Int(stats.cpuPercent.rounded()))%") {
            StatBar(percent: stats.cpuPercent, color: barColor(stats.cpuPercent))
            if stats.cpuCores.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Per-core usage").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Array(stats.cpuCores.enumerated()), id: \.offset) { _, core in
                            StatBar(percent: core, color: barColor(core), height: 5)
                        }
                    }
                }
            }
            sparkline(viewModel.cpuHistory, color: .blue)
        }
    }

    private var temperatureCard: some View {
        card(
            title: "Temperature",
            systemImage: "thermometer.medium",
            trailingText: stats.cpuTempCelsius.map { "\(Int($0.rounded()))°C" },
            trailingColor: stats.cpuTempCelsius.map(tempColor) ?? .primary
        ) {
            if let temp = stats.cpuTempCelsius {
                StatBar(percent: temp, color: barColor(temp))
            } else {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
            if !stats.fanRPMs.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(stats.fanRPMs.enumerated()), id: \.offset) { index, rpm in
                        Text(stats.fanRPMs.count > 1 ? "Fan \(index + 1) \(Int(rpm)) RPM" : "Fan \(Int(rpm)) RPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if stats.cpuTempCelsius != nil {
                sparkline(viewModel.tempHistory, color: stats.cpuTempCelsius.map(tempColor) ?? .blue)
            }
        }
    }

    private var memoryCard: some View {
        card(title: "Memory", systemImage: "memorychip", trailingText: ramText) {
            StatBar(percent: ramPercent, color: barColor(ramPercent))
            if stats.swapTotalMB > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Swap").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(swapText).font(.caption).foregroundStyle(.secondary)
                    }
                    StatBar(percent: swapPercent, color: barColor(swapPercent))
                }
            }
        }
    }

    private var diskCard: some View {
        card(title: "Storage", systemImage: "internaldrive", trailingText: diskText) {
            StatBar(percent: diskPercent, color: barColor(diskPercent))
        }
    }

    private var gpuCard: some View {
        card(
            title: stats.gpuName.map { LocalizedStringKey($0) } ?? "GPU",
            systemImage: "square.stack.3d.up",
            trailingText: stats.gpuPercent.map { "\(Int($0.rounded()))%" }
        ) {
            if let gpuPercent = stats.gpuPercent {
                StatBar(percent: gpuPercent, color: barColor(gpuPercent))
            } else {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func batteryCard(percent: Double) -> some View {
        card(
            title: "Battery",
            systemImage: stats.batteryCharging == true ? "battery.100.bolt" : "battery.100",
            trailingText: "\(Int(percent.rounded()))%"
        ) {
            StatBar(percent: percent, color: batteryBarColor(percent))
            Text(stats.batteryCharging == true ? "Charging" : "On battery")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var uptimeCard: some View {
        card(title: "Uptime", systemImage: "clock", trailingText: uptimeText) {
            Text("Since \(uptimeSinceText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var networkCard: some View {
        card(
            title: "Network",
            systemImage: stats.networkConnected ? (stats.networkType == "Wi-Fi" ? "wifi" : "network") : "wifi.slash",
            trailingText: stats.networkConnected ? "Connected" : "Disconnected",
            trailingColor: stats.networkConnected ? .green : .red
        ) {
            if stats.networkConnected {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stats.networkName.map { "\(stats.networkType ?? "Connected") · \($0)" } ?? (stats.networkType ?? "Connected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let ip = stats.networkLocalIP {
                        Text("Local IP: \(ip)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Label(formatKbps(stats.networkDownloadKbps), systemImage: "arrow.down")
                        Label(formatKbps(stats.networkUploadKbps), systemImage: "arrow.up")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            } else {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Task-Manager-"Apps"-tab-style list — full width, below the metric
    /// cards. Shows apps (icon + display name via `NSRunningApplication`),
    /// not raw process names — a wall of names like `mds_stores` or
    /// `com.apple.WebKit.Networking` was hard to scan at a glance.
    ///
    /// A hand-drawn column list, not a native `Table` — `Table` on macOS is
    /// always backed by its own `NSScrollView`, so no matter how precisely
    /// its frame was sized to fit every row, it kept reserving/showing its
    /// own scroller, fighting the page's outer `ScrollView` for scroll
    /// events. A plain `VStack` of rows has no scroll machinery of its own
    /// at all, so the page's `ScrollView` is unambiguously the only one.
    /// This also happens to fix Quit/Force Quit for real: `Table`'s
    /// per-cell `.contextMenu` never fired (`NSTableView` intercepts
    /// right-click for row selection first) — a plain view's `.contextMenu`
    /// has no such interception.
    ///
    /// Named "Running Apps" rather than the earlier "Top Apps" — that name
    /// stopped fitting once the hard top-8 cap was removed; this now lists
    /// every running app, not just the busiest few.
    ///
    /// Sort order and the search filter live here (not the view model)
    /// because `viewModel.topApps` is replaced wholesale every 2s refresh —
    /// re-deriving the visible rows from that plus local `@State` on every
    /// render keeps the user's chosen sort/filter stable across refreshes
    /// without any extra "reapply after reload" bookkeeping.
    private var processesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Running Apps").font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "chart.bar.fill")
                }
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    processesHeaderRow
                    Divider()
                    if filteredSortedApps.isEmpty {
                        Text("No apps found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredSortedApps) { app in
                            processRow(app)
                            if app.id != filteredSortedApps.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private var processesHeaderRow: some View {
        HStack(spacing: 8) {
            processSortButton("App", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            processSortButton("Status", key: .status)
                .frame(width: Self.statusColumnWidth, alignment: .leading)
            processSortButton("CPU", key: .cpu)
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            processSortButton("Memory", key: .memory)
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .padding(.bottom, 4)
    }

    private func processSortButton(_ title: LocalizedStringKey, key: ProcessSortKey) -> some View {
        Button {
            if processSortKey == key {
                processSortAscending.toggle()
            } else {
                processSortKey = key
                processSortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if processSortKey == key {
                    Image(systemName: processSortAscending ? "chevron.up" : "chevron.down")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func processRow(_ app: AppUsage) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(app.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(app.status.label)
                .foregroundStyle(.secondary)
                .frame(width: Self.statusColumnWidth, alignment: .leading)
            Text("\(app.cpuPercent, specifier: "%.1f")%")
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            Text("\(app.memoryMB, specifier: "%.0f") MB (\(app.memoryPercent, specifier: "%.1f")%)")
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Quit") { app.runningApplication.terminate() }
            Button("Force Quit", role: .destructive) { app.runningApplication.forceTerminate() }
        }
    }

    private var filteredSortedApps: [AppUsage] {
        let filtered = processSearchText.isEmpty
            ? viewModel.topApps
            : viewModel.topApps.filter { $0.name.localizedCaseInsensitiveContains(processSearchText) }
        return filtered.sorted { a, b in
            let ascending: Bool
            switch processSortKey {
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .status: ascending = a.status.rawValue < b.status.rawValue
            case .cpu: ascending = a.cpuPercent < b.cpuPercent
            case .memory: ascending = a.memoryMB < b.memoryMB
            }
            return processSortAscending ? ascending : !ascending
        }
    }

    // MARK: - Formatting

    private var ramText: String {
        String(format: "%.1f / %.1f GB", Double(stats.ramUsedMB) / 1024, Double(stats.ramTotalMB) / 1024)
    }

    private var swapText: String {
        String(format: "%.1f / %.1f GB", Double(stats.swapUsedMB) / 1024, Double(stats.swapTotalMB) / 1024)
    }

    private var diskText: String {
        String(format: "%.0f / %.0f GB", stats.diskUsedGB, stats.diskTotalGB)
    }

    private var uptimeText: String {
        let secs = stats.uptimeSecs
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let minutes = (secs % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Boot time derived from uptime, since the stats provider only reports the duration.
    private var uptimeSinceText: String {
        Date().addingTimeInterval(-Double(stats.uptimeSecs)).formatted(date: .abbreviated, time: .shortened)
    }

    private func formatKbps(_ kbps: Double) -> String {
        kbps >= 1024 ? String(format: "%.1f MB/s", kbps / 1024) : String(format: "%.0f KB/s", kbps)
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .blue
    }

    /// Apple's own thermal throttling starts well above 90°C — 70/85 flags
    /// "running hot" early enough to be a useful heads-up in a monitoring UI.
    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 85 { return .red }
        if celsius >= 70 { return .yellow }
        return .primary
    }

    /// Inverse of `barColor`: for a battery a HIGH percentage is good, so
    /// "danger at the top end" would be backwards.
    private func batteryBarColor(_ percent: Double) -> Color {
        if percent <= 20 { return .red }
        if percent <= 40 { return .yellow }
        return .blue
    }

    @ViewBuilder
    private func sparkline(_ data: [Double], color: Color) -> some View {
        if data.count > 1 {
            Chart(Array(data.enumerated()), id: \.offset) { sample in
                LineMark(x: .value("Tick", sample.offset), y: .value("Value", sample.element))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .foregroundStyle(color)
            .frame(height: Self.sparklineHeight)
            // Purely decorative trend view - the card's trailingText already
            // announces the current numeric value, and `Chart` has no
            // meaningful default accessibility representation of its own
            // (VoiceOver would otherwise stop on an unlabeled element here).
            .accessibilityHidden(true)
        }
    }

    /// `GroupBox` with no `label:` (rather than the built-in label slot used
    /// elsewhere) — the icon/title/value header here is one row inside the
    /// content, matching the old app's card layout, while still getting
    /// `GroupBox`'s automatic system material (Liquid Glass on macOS 26+)
    /// instead of a hand-drawn background.
    @ViewBuilder
    private func card<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        trailingText: String?,
        trailingColor: Color = .primary,
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
                        Text(trailingText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(trailingColor)
                    }
                }
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
        }
        // Applied to the whole `GroupBox`, not just its inner content: an
        // `HStack` row proposes the same height to every child (the row's
        // tallest natural content), and only a view that explicitly accepts
        // `maxHeight: .infinity` at its outermost level actually stretches
        // its drawn background to fill that proposal — the `Spacer` above
        // then absorbs the extra space so a short card's header still sits
        // at the top instead of centered in the taller row.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Thin horizontal progress bar with a color that's chosen by the caller
/// (green/blue "normal" vs. yellow/red thresholds), replacing the plain
/// `Chart`-based sparkline-only cards from the previous design.
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
