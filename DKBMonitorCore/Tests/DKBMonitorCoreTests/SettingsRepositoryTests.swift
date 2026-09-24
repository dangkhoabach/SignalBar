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
            cleanupTargetPaths: "/tmp/a\n/tmp/b",
            // Every overlay field differs from `OverlayConfiguration.defaults`,
            // for the same reason as above.
            overlay: OverlayConfiguration(
                enabled: true, corner: .bottomLeft, offsetX: 40, offsetY: 64,
                display: .named("LG UltraFine"), layout: .horizontal, scale: .large,
                opacityPercent: 55, refreshMillis: 2000, metrics: [.gpu, .cpu, .power],
                showOverFullScreen: false, sparklines: true, background: .solid
            )
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

@Suite struct OverlaySettingsTests {
    private func makeQueue() throws -> DatabaseQueue {
        try AppDatabase(inMemory: DatabaseQueue()).dbQueue
    }

    /// A list the user emptied must stay empty after a relaunch, not come
    /// back as the defaults — an empty string is what "never saved" reads as.
    @Test func anEmptiedMetricListStaysEmpty() throws {
        let queue = try makeQueue()
        let repo = SettingsRepository(dbQueue: queue)
        var settings = AppSettings.defaults
        settings.overlay.metrics = []
        try repo.update(settings)
        #expect(try repo.load().overlay.metrics == [])
    }

    /// Hand-edited or corrupted rows fall back or clamp instead of producing
    /// an invisible, off-screen or tight-looping overlay.
    @Test func invalidStoredValuesAreClampedOrDefaulted() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try AppSettingsStore.set(db, key: "overlay_corner", value: "middle")
            try AppSettingsStore.set(db, key: "overlay_opacity", value: "0")
            try AppSettingsStore.set(db, key: "overlay_refresh_ms", value: "1")
            try AppSettingsStore.set(db, key: "overlay_offset_x", value: "-50")
            try AppSettingsStore.set(db, key: "overlay_offset_y", value: "abc")
        }
        let overlay = try SettingsRepository(dbQueue: queue).load().overlay
        #expect(overlay.corner == OverlayConfiguration.defaults.corner)
        #expect(overlay.opacityPercent == 30)
        #expect(overlay.refreshMillis == 1000)
        #expect(overlay.offsetX == 0)
        #expect(overlay.offsetY == OverlayConfiguration.defaults.offsetY)
    }
}
