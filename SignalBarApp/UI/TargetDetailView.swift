import Charts
import SignalBarCore
import SwiftUI

struct TargetDetailView: View {
    let targetId: Int64

    @State private var viewModel = TargetDetailViewModel(
        repo: AppDatabase.shared.map { TargetRepository(dbQueue: $0.dbQueue) }
    )
    @State private var isShowingCalendar = false

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        statTiles(detail)
                        latencyChart
                        incidentsTimeline(detail)
                        historyTable
                    }
                    .padding()
                }
                .navigationTitle(detail.target.name)
            } else {
                skeleton
            }
        }
        .onAppear { viewModel.start(targetId: targetId) }
        .onDisappear { viewModel.stop() }
    }

    /// `detail` loads via a synchronous DB read (near-instant in practice),
    /// but a skeleton still reads better than a bare spinner floating in
    /// otherwise-empty space — the stat tiles, chart, and table all have a
    /// fixed, well-known shape ahead of time, which is exactly what
    /// `.redacted(reason: .placeholder)` is for.
    private var skeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    tile("Uptime (24h)", systemImage: "clock.arrow.circlepath", value: "00.0%")
                    tile("Uptime (7d)", systemImage: "calendar", value: "00.0%")
                    tile("Incidents", systemImage: "exclamationmark.triangle", value: "0")
                }
                VStack(alignment: .leading) {
                    Text("Latency").font(.headline)
                    Color.clear.frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                }
                VStack(alignment: .leading) {
                    Text("History").font(.headline)
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(minHeight: 200)
                }
            }
            .padding()
        }
        .redacted(reason: .placeholder)
    }

    private func statTiles(_ detail: TargetDetail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            tile(
                "Uptime (24h)", systemImage: "clock.arrow.circlepath",
                value: detail.uptime24hPct.map { String(format: "%.1f%%", $0) } ?? "n/a"
            )
            tile(
                "Uptime (7d)", systemImage: "calendar",
                value: detail.uptime7dPct.map { String(format: "%.1f%%", $0) } ?? "n/a"
            )
            tile(
                "Incidents", systemImage: "exclamationmark.triangle",
                value: "\(detail.incidents.count)"
            )
            if let sslExpiry = detail.sslStatus?.expiryDate {
                tile("SSL Expires", systemImage: "lock.fill", value: sslExpiry.formatted(date: .abbreviated, time: .omitted))
            }
            if let domainExpiry = detail.domainStatus?.expiryDate {
                tile("Domain Expires", systemImage: "globe", value: domainExpiry.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    /// Matches `SystemView.card`'s chrome (icon+title header row over a
    /// `GroupBox`, stretched to fill the row's height) so this page's tiles
    /// read as the same visual language as the System tab's metric cards,
    /// instead of the plain `GroupBox(label:)` tiles used before. Unlike
    /// System's cards, the value text always stays the default color — no
    /// red/yellow threshold coloring here.
    private func tile(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(title).font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: systemImage)
                }
                .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var latencyChart: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latency").font(.headline)
                Spacer()
                // Beside the chart rather than up with the uptime tiles:
                // these describe exactly the checks plotted below, and
                // putting them anywhere else invites reading them as
                // covering some other window.
                if let percentiles = viewModel.latencyPercentiles {
                    Text("p50 \(percentiles.p50)ms · p95 \(percentiles.p95)ms")
                        .font(.subheadline.monospacedDigit())
                    Text("(\(percentiles.sampleCount) ok)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Chart(viewModel.chronologicalHistory) { result in
                if let responseTime = result.responseTimeMs {
                    LineMark(x: .value("Time", result.checkedAt), y: .value("ms", responseTime))
                }
                if !result.success {
                    PointMark(x: .value("Time", result.checkedAt), y: .value("ms", result.responseTimeMs ?? 0))
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 160)
        }
    }

    private func incidentsTimeline(_ detail: TargetDetail) -> some View {
        VStack(alignment: .leading) {
            Text("Incidents").font(.headline)
            if detail.incidents.isEmpty {
                Text("No incidents in this window.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(detail.incidents.enumerated()), id: \.offset) { _, incident in
                    HStack {
                        Image(systemName: incident.endedAt == nil ? "exclamationmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(incident.endedAt == nil ? .red : .secondary)
                        VStack(alignment: .leading) {
                            Text(incidentRangeText(incident))
                            if let error = incident.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
        }
    }

    private func incidentRangeText(_ incident: Incident) -> LocalizedStringKey {
        let start = incident.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = incident.endedAt else { return "\(start) — ongoing" }
        return "\(start) — \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var historyTable: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                // `DatePicker`'s own field style on macOS ignores
                // `.datePickerStyle(.compact)` (that style only exists on
                // iOS — macOS falls back to the same stepper-field look
                // either way) and its text-field editor leaves a component
                // stuck permanently highlighted blue once clicked. A plain
                // `Button` showing the formatted date, popping a real
                // `.graphical` calendar, sidesteps both: no text-editing
                // field means no stuck selection, and it reads as one
                // pill-shaped control like the Overview search field.
                Button {
                    isShowingCalendar = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text(viewModel.selectedDay.formatted(date: .abbreviated, time: .omitted))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingCalendar) {
                    DatePicker("", selection: $viewModel.selectedDay, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                        .onChange(of: viewModel.selectedDay) { _, _ in isShowingCalendar = false }
                }
            }
            if viewModel.historyForSelectedDay.isEmpty {
                Text("No checks on this day.").foregroundStyle(.secondary)
            } else {
                Table(viewModel.historyForSelectedDay) {
                    TableColumn("Time") { Text($0.checkedAt.formatted(date: .omitted, time: .standard)) }
                    TableColumn("Status") { ($0.success ? Text("Up") : Text("Down")).foregroundStyle($0.success ? .green : .red) }
                    TableColumn("Code") { Text($0.statusCode.map(String.init) ?? "—") }
                    TableColumn("Response") { Text($0.responseTimeMs.map { "\($0)ms" } ?? "—") }
                    TableColumn("Error") { Text($0.errorMessage ?? "—") }
                }
                .frame(minHeight: 200)
            }
        }
    }
}
