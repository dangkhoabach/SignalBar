import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

private actor RecordingNotifier: NotificationSending {
    private(set) var notifications: [(title: String, body: String, route: String?)] = []
    func notify(title: String, body: String, route: String?) async {
        notifications.append((title, body, route))
    }
}

private actor RecordingReportSender: ReportSending {
    private(set) var calls: [(label: String, days: Int)] = []
    func sendReport(label: String, days: Int) async -> Bool {
        calls.append((label, days))
        return true
    }
}

private struct StaticStatsProvider: SystemStatsProvider {
    let value: SystemStats
    func snapshot() async -> SystemStats { value }
}

@Suite struct SchedulerTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(inMemory: DatabaseQueue())
    }

    @Test func tickFiresDownAlertOnceThresholdReached() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = true; s.failureAlertThreshold = 1; return s }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender())

        await scheduler.tick()

        let notifications = await notifier.notifications
        #expect(notifications.count == 1)
        #expect(notifications[0].title.contains("đang down"))
    }

    @Test func tickSendsNoNotificationWhenNotificationsDisabled() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = false; s.failureAlertThreshold = 1; return s }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender())

        await scheduler.tick()

        #expect(await notifier.notifications.isEmpty)
    }

    @Test func tickSendsReportOnceWhenDailyReportIsDueThenDedupesOnSecondTick() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.smtpEnabled = true
            s.smtpRecipientEmail = "ops@example.com"
            s.smtpFrequency = "daily"
            return s
        }())

        let reportSender = RecordingReportSender()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: reportSender)

        await scheduler.tick()
        await scheduler.tick()

        let calls = await reportSender.calls
        #expect(calls.count == 1)
        #expect(calls[0].label == "Daily")
    }

    @Test func tickFiresSystemTempAlertOnceThenClearsWhenCooled() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = true; s.systemTempAlertThresholdCelsius = 80; return s }())

        let notifier = RecordingNotifier()
        let hotScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 90))
        )
        await hotScheduler.tick()
        await hotScheduler.tick() // still hot: must not alert again

        let afterHot = await notifier.notifications
        #expect(afterHot.count == 1)
        #expect(afterHot[0].title == "Nhiệt độ máy đang cao")

        let coolScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 50))
        )
        await coolScheduler.tick() // clears the flag, no new alert
        await hotScheduler.tick() // hot again: flag was cleared, must alert again

        let afterCycle = await notifier.notifications
        #expect(afterCycle.count == 2)
    }

    @Test func startAndStopDoNotCrash() async throws {
        let app = try makeDatabase()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: RecordingReportSender())
        await scheduler.start()
        await scheduler.stop()
    }
}

@Suite struct SchedulerAlertDecisionTests {
    private func transition(
        previousFailures: Int = 0, newFailures: Int = 0,
        previousSlow: Int = 0, newSlow: Int = 0, isSlow: Bool = false
    ) -> TargetRepository.AlertTransition {
        TargetRepository.AlertTransition(
            previousFailures: previousFailures, newFailures: newFailures,
            previousSlow: previousSlow, newSlow: newSlow, isSlow: isSlow
        )
    }

    /// The regression this suite exists for: a target that answered slowly for
    /// `threshold` checks and then failed outright used to report "response
    /// time back to normal" — the reassuring message, at the exact moment it
    /// started going down. A failed check never means the response time
    /// recovered, so it must produce no alert until the failure streak
    /// reaches the threshold.
    @Test func aFailureAfterASlowStreakDoesNotClaimTheResponseTimeRecovered() {
        let firstFailure = transition(previousFailures: 0, newFailures: 1, previousSlow: 2, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: false, transition: firstFailure, threshold: 2) == nil)
    }

    /// The down alert still arrives on the check that reaches the threshold,
    /// so the slow streak only delays it, never replaces it.
    @Test func theDownAlertStillFiresOnceTheFailureStreakReachesTheThreshold() {
        let secondFailure = transition(previousFailures: 1, newFailures: 2, previousSlow: 0, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: false, transition: secondFailure, threshold: 2) == .down)
    }

    /// A genuine response-time recovery — a successful, no-longer-slow check
    /// after a slow streak — must still alert.
    @Test func aSuccessfulFastCheckAfterASlowStreakReportsTheRecovery() {
        let recovered = transition(previousFailures: 0, newFailures: 0, previousSlow: 2, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: true, transition: recovered, threshold: 2) == .responseTimeNormal)
    }

    @Test func aSlowStreakReachingTheThresholdReportsSlow() {
        let slow = transition(previousSlow: 1, newSlow: 2, isSlow: true)
        #expect(Scheduler.alert(success: true, transition: slow, threshold: 2) == .slow)
    }

    @Test func aSuccessAfterAFailureStreakReportsBackUp() {
        let backUp = transition(previousFailures: 2, newFailures: 0)
        #expect(Scheduler.alert(success: true, transition: backUp, threshold: 2) == .backUp)
    }

    /// Steady state on both sides: nothing to say.
    @Test func anUneventfulCheckProducesNoAlert() {
        #expect(Scheduler.alert(success: true, transition: transition(), threshold: 2) == nil)
        #expect(Scheduler.alert(success: false, transition: transition(newFailures: 1), threshold: 2) == nil)
    }
}
