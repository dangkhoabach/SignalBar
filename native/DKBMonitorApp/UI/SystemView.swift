import Charts
import DKBMonitorCore
import SwiftUI

struct SystemView: View {
    @Bindable private var viewModel = SystemViewModel.shared

    private var stats: SystemStats { viewModel.current }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                statCard(title: "CPU", value: "\(Int(stats.cpuPercent.rounded()))%", history: viewModel.cpuHistory)
                statCard(title: "RAM", value: ramText, history: viewModel.ramHistory)
                statCard(title: "Swap", value: swapText, history: nil)
                statCard(title: "Disk", value: diskText, history: nil)
                if let gpuName = stats.gpuName {
                    statCard(title: gpuName, value: stats.gpuPercent.map { "\(Int($0.rounded()))%" } ?? "N/A", history: nil)
                }
                statCard(title: "Temperature", value: stats.cpuTempCelsius.map { "\(Int($0.rounded()))°C" } ?? "N/A", history: nil)
                if let battery = stats.batteryPercent {
                    statCard(title: "Battery", value: "\(Int(battery.rounded()))%\(stats.batteryCharging == true ? " (Charging)" : "")", history: nil)
                }
                if !stats.fanRPMs.isEmpty {
                    statCard(title: "Fan", value: stats.fanRPMs.map { "\(Int($0)) RPM" }.joined(separator: ", "), history: nil)
                }
                statCard(title: "Network", value: networkText, history: nil)
                statCard(title: "Download", value: String(format: "%.1f KB/s", stats.networkDownloadKbps), history: viewModel.downloadHistory)
                statCard(title: "Upload", value: String(format: "%.1f KB/s", stats.networkUploadKbps), history: viewModel.uploadHistory)
                statCard(title: "Uptime", value: uptimeText, history: nil)
            }
            .padding()
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var ramText: String {
        String(format: "%.1f / %.1f GB", Double(stats.ramUsedMB) / 1024, Double(stats.ramTotalMB) / 1024)
    }

    private var swapText: String {
        stats.swapTotalMB > 0
            ? String(format: "%.1f / %.1f GB", Double(stats.swapUsedMB) / 1024, Double(stats.swapTotalMB) / 1024)
            : "None"
    }

    private var diskText: String {
        String(format: "%.0f / %.0f GB", stats.diskUsedGB, stats.diskTotalGB)
    }

    private var networkText: String {
        guard stats.networkConnected else { return "Disconnected" }
        var parts = [stats.networkType ?? "Connected"]
        if let name = stats.networkName { parts.append(name) }
        if let ip = stats.networkLocalIP { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    private var uptimeText: String {
        "\(stats.uptimeSecs / 3600)h \((stats.uptimeSecs % 3600) / 60)m"
    }

    @ViewBuilder
    private func statCard(title: String, value: String, history: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
            if let history, history.count > 1 {
                Chart(Array(history.enumerated()), id: \.offset) { sample in
                    LineMark(x: .value("Tick", sample.offset), y: .value("Value", sample.element))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 32)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
