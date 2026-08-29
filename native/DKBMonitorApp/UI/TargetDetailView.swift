import Charts
import DKBMonitorCore
import SwiftUI

struct TargetDetailView: View {
    let targetId: Int64

    @State private var viewModel = TargetDetailViewModel(
        repo: (try? AppDatabase(path: AppDatabaseLocation.productionPath().path)).map { TargetRepository(dbQueue: $0.dbQueue) }
    )

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
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { viewModel.load(targetId: targetId) }
    }

    private func statTiles(_ detail: TargetDetail) -> some View {
        HStack(spacing: 12) {
            tile("Uptime (24h)", detail.uptime24hPct.map { String(format: "%.1f%%", $0) } ?? "n/a")
            tile("Uptime (7d)", detail.uptime7dPct.map { String(format: "%.1f%%", $0) } ?? "n/a")
            tile("Incidents", "\(detail.incidents.count)")
            if let sslExpiry = detail.sslStatus?.expiryDate {
                tile("SSL Expires", sslExpiry.formatted(date: .abbreviated, time: .omitted))
            }
            if let domainExpiry = detail.domainStatus?.expiryDate {
                tile("Domain Expires", domainExpiry.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var latencyChart: some View {
        VStack(alignment: .leading) {
            Text("Latency").font(.headline)
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

    private func incidentRangeText(_ incident: Incident) -> String {
        let start = incident.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = incident.endedAt else { return "\(start) — ongoing" }
        return "\(start) — \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var historyTable: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                DatePicker("", selection: $viewModel.selectedDay, displayedComponents: .date)
                    .labelsHidden()
            }
            if viewModel.historyForSelectedDay.isEmpty {
                Text("No checks on this day.").foregroundStyle(.secondary)
            } else {
                Table(viewModel.historyForSelectedDay) {
                    TableColumn("Time") { Text($0.checkedAt.formatted(date: .omitted, time: .standard)) }
                    TableColumn("Status") { Text($0.success ? "Up" : "Down").foregroundStyle($0.success ? .green : .red) }
                    TableColumn("Code") { Text($0.statusCode.map(String.init) ?? "—") }
                    TableColumn("Response") { Text($0.responseTimeMs.map { "\($0)ms" } ?? "—") }
                    TableColumn("Error") { Text($0.errorMessage ?? "—") }
                }
                .frame(minHeight: 200)
            }
        }
    }
}
