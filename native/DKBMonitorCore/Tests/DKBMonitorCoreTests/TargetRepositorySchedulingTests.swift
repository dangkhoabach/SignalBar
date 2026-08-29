import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct TargetRepositorySchedulingTests {
    private func makeRepo() throws -> TargetRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return TargetRepository(dbQueue: app.dbQueue)
    }

    @Test func dueForHTTPCheckIncludesNeverCheckedEnabledTargets() throws {
        let repo = try makeRepo()
        _ = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        #expect(try repo.dueForHTTPCheck().count == 1)
    }

    @Test func dueForHTTPCheckExcludesDisabledTargets() throws {
        let repo = try makeRepo()
        var target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        target.enabled = false
        _ = try repo.update(target)
        #expect(try repo.dueForHTTPCheck().isEmpty)
    }

    @Test func dueForHTTPCheckExcludesIndefinitelyPausedTargets() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try repo.pause(id: target.id!, until: nil)
        #expect(try repo.dueForHTTPCheck().isEmpty)
    }

    @Test func dueForHTTPCheckExcludesPausedUntilFutureTargets() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        try repo.pause(id: target.id!, until: Date(timeIntervalSinceNow: 3600))
        #expect(try repo.dueForHTTPCheck().isEmpty)
    }

    @Test func dueForHTTPCheckExcludesRecentlyCheckedTargets() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com", checkIntervalSecs: 300))
        try repo.storeCheckResult(
            targetId: target.id!,
            outcome: HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 10, errorMessage: nil),
            responseTimeAlertThresholdMs: 0
        )
        #expect(try repo.dueForHTTPCheck().isEmpty)
    }

    @Test func dueForSSLAndDomainCheckRespectTheirOwnFlags() throws {
        let repo = try makeRepo()
        _ = try repo.add(NewTargetInput(name: "SSL only", url: "https://a.com", checkSSL: true, checkDomain: false))
        _ = try repo.add(NewTargetInput(name: "Domain only", url: "https://b.com", checkSSL: false, checkDomain: true))

        #expect(try repo.dueForSSLCheck(intervalSecs: 86_400).map(\.name) == ["SSL only"])
        #expect(try repo.dueForDomainCheck(intervalSecs: 86_400).map(\.name) == ["Domain only"])
    }

    @Test func storeCheckResultTracksConsecutiveFailuresAndResetsOnSuccess() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let failing = HttpCheckOutcome(success: false, statusCode: nil, responseTimeMs: 5, errorMessage: "timeout")

        let first = try repo.storeCheckResult(targetId: target.id!, outcome: failing, responseTimeAlertThresholdMs: 0)
        #expect(first.previousFailures == 0)
        #expect(first.newFailures == 1)

        let second = try repo.storeCheckResult(targetId: target.id!, outcome: failing, responseTimeAlertThresholdMs: 0)
        #expect(second.previousFailures == 1)
        #expect(second.newFailures == 2)

        let succeeding = HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 5, errorMessage: nil)
        let recovered = try repo.storeCheckResult(targetId: target.id!, outcome: succeeding, responseTimeAlertThresholdMs: 0)
        #expect(recovered.previousFailures == 2)
        #expect(recovered.newFailures == 0)
    }

    @Test func storeCheckResultTracksConsecutiveSlowResponses() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let slow = HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 5000, errorMessage: nil)

        let first = try repo.storeCheckResult(targetId: target.id!, outcome: slow, responseTimeAlertThresholdMs: 1000)
        #expect(first.isSlow)
        #expect(first.newSlow == 1)

        let fast = HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 10, errorMessage: nil)
        let recovered = try repo.storeCheckResult(targetId: target.id!, outcome: fast, responseTimeAlertThresholdMs: 1000)
        #expect(!recovered.isSlow)
        #expect(recovered.previousSlow == 1)
        #expect(recovered.newSlow == 0)
    }

    @Test func storeSSLStatusAlertsOnceBelowThresholdThenDedupesForTheDay() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let expiringSoon = Date(timeIntervalSinceNow: 3 * 86400)

        let first = try repo.storeSSLStatus(targetId: target.id!, expiryDate: expiringSoon, thresholdDays: 14)
        #expect(first.shouldAlert)
        #expect(first.daysRemaining == 3)

        let second = try repo.storeSSLStatus(targetId: target.id!, expiryDate: expiringSoon, thresholdDays: 14)
        #expect(!second.shouldAlert, "already alerted today for this target, must not alert again until tomorrow")
    }

    @Test func storeDomainStatusDoesNotAlertWhenFarFromThreshold() throws {
        let repo = try makeRepo()
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))
        let farFuture = Date(timeIntervalSinceNow: 200 * 86400)

        let transition = try repo.storeDomainStatus(targetId: target.id!, expiryDate: farFuture, thresholdDays: 30)
        #expect(!transition.shouldAlert)
    }
}
