import Foundation
import Testing
@testable import DKBMonitorCore

@Suite struct IncidentTests {
    private func check(_ minutesAgo: Int, success: Bool, error: String? = nil) -> CheckResult {
        CheckResult(targetId: 1, checkedAt: Date(timeIntervalSinceNow: TimeInterval(-minutesAgo * 60)), success: success, errorMessage: error)
    }

    @Test func groupsConsecutiveFailuresIntoOneIncident() {
        // DESC order (most-recent-first), as the repository returns it.
        let history = [check(0, success: true), check(5, success: false, error: "timeout"), check(10, success: false, error: "timeout"), check(15, success: true)]
        let incidents = history.buildIncidents()
        #expect(incidents.count == 1)
        #expect(incidents[0].errorMessage == "timeout")
        #expect(incidents[0].endedAt != nil)
    }

    @Test func ongoingIncidentHasNoEndDate() {
        let history = [check(0, success: false, error: "down"), check(5, success: false, error: "down"), check(10, success: true)]
        let incidents = history.buildIncidents()
        #expect(incidents.count == 1)
        #expect(incidents[0].endedAt == nil)
    }

    @Test func noFailuresMeansNoIncidents() {
        let history = [check(0, success: true), check(5, success: true)]
        #expect(history.buildIncidents().isEmpty)
    }
}
