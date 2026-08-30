import Charts
import DKBMonitorCore
import SwiftUI

/// Ported layout from the old Tauri app's `src/pages/System.tsx`: a fixed
/// 2-column grid of cards, each combining related metrics (Swap nested under
/// Memory, fan RPMs nested under Temperature) rather than one metric per
/// card, with color-coded progress bars and per-core CPU usage — richer than
/// the original SwiftUI-only redesign, which the user found too sparse next
/// to the app it's replacing.
struct SystemView: View {
    @Bindable private var viewModel = SystemViewModel.shared

    private var stats: SystemStats { viewModel.current }

    private static let gridSpacing: CGFloat = 18
    private static let outerPadding: CGFloat = 24
    private static let sparklineHeight: CGFloat = 32
    /// `LazyVGrid` sizes each cell to its own content — unlike `Grid`, it
    /// does not equalize height row-by-row — so cards ranged from CPU's tall
    /// per-core/sparkline block down to a single-line Storage bar. A shared
    /// minimum (sized to the tallest card, CPU) makes every card the same
    /// footprint regardless of how little it has to show.
    private static let cardMinHeight: CGFloat = 210

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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Self.gridSpacing), GridItem(.flexible())], spacing: Self.gridSpacing) {
                    cpuCard
                    temperatureCard
                    if stats.gpuName != nil {
                        gpuCard
                    }
                    memoryCard
                    diskCard
                    networkCard
                    if let battery = stats.batteryPercent {
                        batteryCard(percent: battery)
                    }
                    uptimeCard
                }
                .padding(Self.outerPadding)
            } else {
                skeletonGrid
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Self.gridSpacing), GridItem(.flexible())], spacing: Self.gridSpacing) {
            ForEach(0..<8, id: \.self) { _ in
                card(title: "Loading", systemImage: "circle.dashed", trailingText: "00%") {
                    StatBar(percent: 0, color: .blue)
                }
            }
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
            .frame(maxWidth: .infinity, minHeight: Self.cardMinHeight, alignment: .topLeading)
            .padding(10)
        }
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
