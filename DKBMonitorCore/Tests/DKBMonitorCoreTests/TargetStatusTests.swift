import Foundation
import Testing
@testable import DKBMonitorCore

@Suite struct TargetStatusTests {
    private func overview(
        enabled: Bool = true,
        pausedIndefinitely: Bool = false,
        pausedUntil: Date? = nil,
        latestSuccess: Bool? = nil
    ) -> TargetOverview {
        var target = Target(id: 1, name: "T", url: "https://t.example")
        target.enabled = enabled
        target.pausedIndefinitely = pausedIndefinitely
        target.pausedUntil = pausedUntil
        let latestCheck = latestSuccess.map { CheckResult(targetId: 1, success: $0) }
        return TargetOverview(target: target, latestCheck: latestCheck, sslStatus: nil, domainStatus: nil, uptime24hPct: nil)
    }

    @Test func disabledTakesPriorityOverEverything() {
        let status = TargetStatus(overview: overview(enabled: false, pausedIndefinitely: true, latestSuccess: true))
        #expect(status == .disabled)
    }

    @Test func pausedTakesPriorityOverCheckResult() {
        let status = TargetStatus(overview: overview(pausedIndefinitely: true, latestSuccess: false))
        #expect(status == .paused)
    }

    @Test func expiredPauseIsNotPaused() {
        let status = TargetStatus(overview: overview(pausedUntil: Date(timeIntervalSinceNow: -60), latestSuccess: true))
        #expect(status == .up)
    }

    @Test func noCheckYetIsUnchecked() {
        #expect(TargetStatus(overview: overview()) == .unchecked)
    }

    @Test func reflectsLatestCheckOutcome() {
        #expect(TargetStatus(overview: overview(latestSuccess: true)) == .up)
        #expect(TargetStatus(overview: overview(latestSuccess: false)) == .down)
    }
}
