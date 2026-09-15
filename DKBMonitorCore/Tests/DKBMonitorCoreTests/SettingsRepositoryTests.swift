import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct SettingsRepositoryTests {
    private func makeRepo() throws -> SettingsRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return SettingsRepository(dbQueue: app.dbQueue)
    }

    /// Every field must survive a write followed by a read.
    ///
    /// This is the test that earns its keep: `load` and `update` each spell
    /// out the same `app_settings` keys by hand, in two separate
    /// lists. One typo on either side is invisible — the write lands under a
    /// key nothing reads, and the setting silently reverts to its default the
    /// next time the app starts. Round-tripping values that are all distinct
    /// from the defaults is what makes such a mismatch fail here.
    @Test func everySettingSurvivesARoundTrip() throws {
        let repo = try makeRepo()
        let settings = AppSettings(
            notificationsEnabled: true,
            smtpEnabled: true,
            smtpRecipientEmail: "ops@example.com",
            // Deliberately different from the recipient: the two are separate
            // keys, so a round trip that used the same value for both would
            // pass even if `load` read one of them from the other's key.
            smtpVerifiedEmail: "verified@example.com",
            smtpFrequency: "weekly",
            smtpDayOfWeek: 3,
            smtpDayOfMonth: 17,
            failureAlertThreshold: 5,
            responseTimeAlertThresholdMs: 1_500,
            sslAlertThresholdDays: 21,
            domainAlertThresholdDays: 45,
            historyRetentionDays: 120,
            systemTempAlertThresholdCelsius: 85,
            batteryLowAlertThresholdPercent: 15,
            httpCheckIntervalSecs: 60,
            webhookEnabled: true,
            webhookURL: "https://hooks.slack.com/services/T0/B0/xxx",
            remoteCPUAlertThresholdPercent: 85,
            remoteMemoryAlertThresholdPercent: 90,
            remoteDiskAlertThresholdPercent: 95,
            cleanupScheduleEnabled: true,
            cleanupFrequency: "monthly",
            cleanupDayOfWeek: 4,
            cleanupDayOfMonth: 17,
            cleanupTargetPaths: "/tmp/a\n/tmp/b"
        )
        try repo.update(settings)
        #expect(try repo.load() == settings)
    }

    @Test func aFreshDatabaseLoadsTheDefaults() throws {
        #expect(try makeRepo().load() == AppSettings.defaults)
    }

    /// The alert thresholds are the fields most likely to be missing on an
    /// install that predates them, and a `nil` threshold would mean "never
    /// alert" — the failure nobody notices.
    @Test func aThresholdMissingFromTheDatabaseFallsBackToItsDefault() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = SettingsRepository(dbQueue: app.dbQueue)
        try app.dbQueue.write { db in
            try AppSettingsStore.set(db, key: "smtp_recipient_email", value: "only@example.com")
        }

        let loaded = try repo.load()
        #expect(loaded.smtpRecipientEmail == "only@example.com")
        #expect(loaded.failureAlertThreshold == AppSettings.defaults.failureAlertThreshold)
        #expect(loaded.sslAlertThresholdDays == AppSettings.defaults.sslAlertThresholdDays)
        #expect(loaded.historyRetentionDays == AppSettings.defaults.historyRetentionDays)
        #expect(loaded.httpCheckIntervalSecs == AppSettings.defaults.httpCheckIntervalSecs)
    }

    /// `app_settings` stores every value as text, so a row corrupted by hand
    /// or by an older build can hold something that isn't a number at all.
    @Test func anUnparseableNumberFallsBackToItsDefaultRatherThanZero() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = SettingsRepository(dbQueue: app.dbQueue)
        try app.dbQueue.write { db in
            try AppSettingsStore.set(db, key: "failure_alert_threshold", value: "not-a-number")
            try AppSettingsStore.set(db, key: "http_check_interval_secs", value: "")
        }

        let loaded = try repo.load()
        #expect(loaded.failureAlertThreshold == AppSettings.defaults.failureAlertThreshold)
        #expect(loaded.httpCheckIntervalSecs == AppSettings.defaults.httpCheckIntervalSecs)
    }

    /// Only "1" means on, so a stray value can't flip notifications on.
    @Test func booleansReadOnlyExactlyOneAsTrue() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = SettingsRepository(dbQueue: app.dbQueue)
        try app.dbQueue.write { db in
            try AppSettingsStore.set(db, key: "notifications_enabled", value: "true")
            try AppSettingsStore.set(db, key: "smtp_enabled", value: "1")
        }

        let loaded = try repo.load()
        #expect(loaded.notificationsEnabled == false)
        #expect(loaded.smtpEnabled == true)
    }

    @Test func updateOverwritesRatherThanAccumulatingRows() throws {
        let repo = try makeRepo()
        var settings = AppSettings.defaults
        settings.smtpRecipientEmail = "first@example.com"
        try repo.update(settings)
        settings.smtpRecipientEmail = "second@example.com"
        try repo.update(settings)

        #expect(try repo.load().smtpRecipientEmail == "second@example.com")
    }
}
