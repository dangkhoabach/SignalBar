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
