import Foundation
import Testing
@testable import DKBMonitorCore

@Suite struct RemoteResourceAlertsTests {
    private func stats(
        cpu: Double? = nil,
        memory: RemoteMemoryUsage? = nil,
        diskUsePercent: String? = nil
    ) -> RemoteServerStats {
        var result = RemoteServerStats()
        if let cpu { result.cpu = RemoteCPUUsage(busyPercent: cpu) }
        result.memory = memory
        if let diskUsePercent {
            result.disk = RemoteDiskUsage(size: "20G", used: "8G", available: "11G", usePercent: diskUsePercent)
        }
        return result
    }

    private let all80 = RemoteResourceThresholds(cpuPercent: 80, memoryPercent: 80, diskPercent: 80)

    // MARK: - Thresholds

    @Test func nothingBreachesWhenEverythingIsBelowItsThreshold() {
        let breaches = RemoteResourceAlerts.breaches(
            in: stats(cpu: 10, memory: RemoteMemoryUsage(totalMB: 1000, usedMB: 100, freeMB: 900, availableMB: 900), diskUsePercent: "20%"),
            thresholds: all80
        )
        #expect(breaches.isEmpty)
    }

    /// The threshold is the alerting point, not the first value past it — a
    /// disk reported at exactly 90% with a 90% threshold is the case people
    /// set the threshold for.
    @Test func exactlyAtTheThresholdCounts() {
        let breaches = RemoteResourceAlerts.breaches(in: stats(diskUsePercent: "80%"), thresholds: all80)
        #expect(breaches.map(\.resource) == [.disk])
    }

    @Test func everyBreachedResourceIsReported() {
        let breaches = RemoteResourceAlerts.breaches(
            in: stats(cpu: 95, memory: RemoteMemoryUsage(totalMB: 1000, usedMB: 900, freeMB: 100, availableMB: 50), diskUsePercent: "99%"),
            thresholds: all80
        )
        #expect(Set(breaches.map(\.resource)) == [.cpu, .memory, .disk])
    }

    /// 0 is the "don't alert on this" convention the local temperature and
    /// battery thresholds already use.
    @Test func aZeroThresholdDisablesThatResource() {
        let breaches = RemoteResourceAlerts.breaches(
            in: stats(cpu: 99, diskUsePercent: "99%"),
            thresholds: RemoteResourceThresholds(cpuPercent: 0, memoryPercent: 0, diskPercent: 90)
        )
        #expect(breaches.map(\.resource) == [.disk])
    }

    @Test func aMissingReadingCannotBreach() {
        #expect(RemoteResourceAlerts.breaches(in: RemoteServerStats(), thresholds: all80).isEmpty)
    }

    @Test func allDisabledIsTrueOnlyWhenNoThresholdIsSet() {
        #expect(RemoteResourceThresholds(cpuPercent: 0, memoryPercent: 0, diskPercent: 0).allDisabled)
        #expect(!RemoteResourceThresholds(cpuPercent: 0, memoryPercent: 0, diskPercent: 1).allDisabled)
    }

    // MARK: - Memory

    /// `free -m`'s `used` excludes buffers and cache, which Linux hands back
    /// on demand, so a server can read as 90% "used" with plenty of room.
    /// Alerting on `available` is what makes the number mean pressure.
    @Test func memoryIsMeasuredAgainstAvailableNotUsed() {
        let cachedHeavily = RemoteMemoryUsage(totalMB: 1000, usedMB: 900, freeMB: 20, availableMB: 800)
        #expect(RemoteResourceAlerts.memoryPercent(cachedHeavily) == 20)

        let genuinelyTight = RemoteMemoryUsage(totalMB: 1000, usedMB: 400, freeMB: 20, availableMB: 50)
        #expect(RemoteResourceAlerts.memoryPercent(genuinelyTight) == 95)
    }

    /// Older `procps` builds don't print the `available` column at all.
    @Test func memoryFallsBackToUsedWhenAvailableIsMissing() {
        let usage = RemoteMemoryUsage(totalMB: 1000, usedMB: 750, freeMB: 250)
        #expect(RemoteResourceAlerts.memoryPercent(usage) == 75)
    }

    @Test func aZeroTotalIsNotDividedBy() {
        #expect(RemoteResourceAlerts.memoryPercent(RemoteMemoryUsage(totalMB: 0, usedMB: 0, freeMB: 0)) == nil)
    }

    // MARK: - Disk

    @Test func diskUseIsReadOutOfDfsPercentString() {
        #expect(RemoteResourceAlerts.diskPercent(RemoteDiskUsage(size: "", used: "", available: "", usePercent: "43%")) == 43)
        #expect(RemoteResourceAlerts.diskPercent(RemoteDiskUsage(size: "", used: "", available: "", usePercent: " 7% ")) == 7)
    }

    @Test func anUnreadableDiskPercentIsNotGuessedAt() {
        #expect(RemoteResourceAlerts.diskPercent(RemoteDiskUsage(size: "", used: "", available: "", usePercent: "-")) == nil)
    }

    // MARK: - Wording

    @Test func theAlertBodyRoundsRatherThanImplyingPrecision() {
        let breach = RemoteResourceBreach(resource: .disk, percent: 87.34, threshold: 80)
        #expect(RemoteResourceAlerts.alertBody(breach) == "87% (ngưỡng 80%)")
    }
}
