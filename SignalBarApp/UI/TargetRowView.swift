import SignalBarCore
import SwiftUI

struct TargetRowView: View {
    let overview: TargetOverview
    let viewModel: OverviewViewModel
    let onViewDetails: () -> Void

    private var status: TargetStatus { TargetStatus(overview: overview) }
    private var targetId: Int64 { overview.target.id ?? -1 }
    private var isChecking: Bool { viewModel.checkingIds.contains(targetId) }

    var body: some View {
        HStack(spacing: 14) {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("Checking")
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(status.localizedLabel)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(overview.target.name).font(.headline)
                Text(overview.target.url).font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 20) {
                if let uptime = overview.uptime24hPct {
                    Text("\(uptime, specifier: "%.1f")% uptime")
                        .frame(minWidth: 90, alignment: .trailing)
                }
                if let responseTime = overview.latestCheck?.responseTimeMs {
                    Text("\(responseTime)ms")
                        .frame(minWidth: 44, alignment: .trailing)
                }
                if let sslExpiry = overview.sslStatus?.expiryDate {
                    Text("SSL: \(sslExpiry.formatted(date: .abbreviated, time: .omitted))")
                        .frame(minWidth: 120, alignment: .trailing)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(status.localizedLabel)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(status.color.opacity(0.15), in: Capsule())
                .foregroundStyle(status.color)
                .frame(minWidth: 70)

            Toggle("", isOn: Binding(
                get: { overview.target.enabled },
                set: { _ in viewModel.toggleEnabled(overview) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        // Explicit minHeight, not just vertical padding, so List has a
        // concrete row height to lay out with on the very first frame —
        // without it, List briefly estimates a smaller height, overlapping
        // rows until any scroll forces a relayout with the real size.
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        // `.simultaneousGesture`, not `.gesture`/`.onTapGesture(count: 2)`:
        // the latter is *exclusive* and forces SwiftUI to make List's own
        // single-click-to-select gesture wait out the double-click
        // disambiguation window before committing (the original delay +
        // inconsistent selection-color bug). A simultaneous gesture is
        // recognized alongside List's selection instead of competing with
        // it for priority, so a single click still selects immediately and
        // a second one additionally opens the detail view.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onViewDetails() })
        .contextMenu {
            Button("View Details") { onViewDetails() }
            Button("Check Now") { viewModel.checkNow(id: targetId) }
                .disabled(isChecking)
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
            Button(role: .destructive) { viewModel.pendingDeleteId = targetId } label: { Text("Delete") }
        }
    }
}
