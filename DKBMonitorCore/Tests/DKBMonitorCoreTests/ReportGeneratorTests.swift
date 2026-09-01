import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct ReportGeneratorTests {
    @Test func reportsNoTargetsWhenEmpty() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let report = try ReportGenerator.generate(dbQueue: app.dbQueue, label: "Daily", days: 1)
        #expect(report.contains("No targets configured."))
    }

    @Test func includesUptimeFailureCountAndExpiryDates() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = TargetRepository(dbQueue: app.dbQueue)
        let target = try repo.add(NewTargetInput(name: "Example", url: "https://example.com"))

        _ = try repo.storeCheckResult(
            targetId: target.id!,
            outcome: HttpCheckOutcome(success: true, statusCode: 200, responseTimeMs: 10, errorMessage: nil),
            responseTimeAlertThresholdMs: 0
        )
        _ = try repo.storeCheckResult(
            targetId: target.id!,
            outcome: HttpCheckOutcome(success: false, statusCode: nil, responseTimeMs: 10, errorMessage: "timeout"),
            responseTimeAlertThresholdMs: 0
        )
        _ = try repo.storeSSLStatus(targetId: target.id!, expiryDate: Date(timeIntervalSinceNow: 10 * 86400), thresholdDays: 14)

        let report = try ReportGenerator.generate(dbQueue: app.dbQueue, label: "Weekly", days: 7)

        #expect(report.contains("DKB Monitor — Weekly Report (last 7 days)"))
        #expect(report.contains("- Example:"))
        #expect(report.contains("50.0% uptime"))
        #expect(report.contains("1 failed checks"))
        #expect(report.contains("SSL expires"))
    }

    @Test func excludesExpiryLinesWhenNoStatusStored() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = TargetRepository(dbQueue: app.dbQueue)
        _ = try repo.add(NewTargetInput(name: "NoChecksYet", url: "https://a.com"))

        let report = try ReportGenerator.generate(dbQueue: app.dbQueue, label: "Monthly", days: 30)

        #expect(report.contains("- NoChecksYet: n/a uptime, 0 failed checks"))
        #expect(!report.contains("SSL expires"))
        #expect(!report.contains("domain expires"))
    }
}

@Suite struct EmailReportSenderTests {
    // The actual HTTPS POST to the production relay is deliberately not
    // exercised here — a real send there would deliver a genuine email.
    // These tests only cover the guard logic that runs before any network
    // call is made.
    @Test func doesNotSendWhenRecipientEmailIsBlank() async throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let sender = EmailReportSender(dbQueue: app.dbQueue)
        let sent = await sender.sendReport(label: "Daily", days: 1)
        #expect(!sent)
    }
}
