import DKBMonitorCore
import Foundation
import Observation

/// Drives the System pane: polls `SystemStatsProvider` every 2s (per Mục 3)
/// and keeps a rolling 1-minute window per metric for the sparklines —
/// same `Task.sleep`-loop shape as `MenuBarStatsViewModel`/`OverviewViewModel`.
@MainActor
@Observable
final class SystemViewModel {
    private static let refreshIntervalSecs: UInt64 = 2
    private static let historyLimit = 30

    static let shared = SystemViewModel(statsProvider: SystemStatsService())

    private let statsProvider: SystemStatsProvider
    private var loopTask: Task<Void, Never>?

    var current = SystemStats()
    var cpuHistory: [Double] = []
    var ramHistory: [Double] = []
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []

    init(statsProvider: SystemStatsProvider) {
        self.statsProvider = statsProvider
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func refresh() async {
        let stats = await statsProvider.snapshot()
        current = stats
        appendClamped(&cpuHistory, stats.cpuPercent)
        let ramPercent = stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
        appendClamped(&ramHistory, ramPercent)
        appendClamped(&downloadHistory, stats.networkDownloadKbps)
        appendClamped(&uploadHistory, stats.networkUploadKbps)
    }

    private func appendClamped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLimit {
            array.removeFirst(array.count - Self.historyLimit)
        }
    }
}
