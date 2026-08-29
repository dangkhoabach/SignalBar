import DKBMonitorCore
import SwiftUI

struct TargetRowView: View {
    let overview: TargetOverview
    let viewModel: OverviewViewModel
    let onViewDetails: () -> Void

    private var status: TargetStatus { TargetStatus(overview: overview) }
    private var targetId: Int64 { overview.target.id ?? -1 }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(overview.target.name).font(.headline)
                Text(overview.target.url).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if let uptime = overview.uptime24hPct {
                Text("\(uptime, specifier: "%.1f")% uptime")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let responseTime = overview.latestCheck?.responseTimeMs {
                Text("\(responseTime)ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let sslExpiry = overview.sslStatus?.expiryDate {
                Text("SSL: \(sslExpiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(status.localizedLabel)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(status.color.opacity(0.15), in: Capsule())
                .foregroundStyle(status.color)

            Toggle("", isOn: Binding(
                get: { overview.target.enabled },
                set: { _ in viewModel.toggleEnabled(overview) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onViewDetails() }
        .contextMenu {
            Button("View Details") { onViewDetails() }
            Button("Check Now") { viewModel.checkNow(id: targetId) }
            Menu("Pause") {
                Button("30 minutes") { viewModel.pause(id: targetId, duration: 30 * 60) }
                Button("1 hour") { viewModel.pause(id: targetId, duration: 60 * 60) }
                Button("4 hours") { viewModel.pause(id: targetId, duration: 4 * 60 * 60) }
                Button("24 hours") { viewModel.pause(id: targetId, duration: 24 * 60 * 60) }
                Button("Indefinitely") { viewModel.pause(id: targetId, duration: nil) }
            }
            if overview.target.isPaused() {
                Button("Resume") { viewModel.resume(id: targetId) }
            }
            Button("Edit…") { viewModel.editingTarget = overview.target }
            Button(role: .destructive) { viewModel.delete(id: targetId) } label: { Text("Delete") }
        }
    }
}
