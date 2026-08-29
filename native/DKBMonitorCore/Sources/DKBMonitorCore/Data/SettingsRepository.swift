import Foundation
import GRDB

public struct AppSettings: Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var smtpEnabled: Bool
    public var smtpRecipientEmail: String
    /// "daily" | "weekly" | "monthly"
    public var smtpFrequency: String
    public var smtpDayOfWeek: Int
    public var smtpDayOfMonth: Int
    /// Consecutive HTTP failures before a "target is down" alert fires.
    public var failureAlertThreshold: Int
    /// Response time (ms) a successful check must exceed, for
    /// `failureAlertThreshold` consecutive checks, before a "slow" alert
    /// fires. 0 disables this alert.
    public var responseTimeAlertThresholdMs: Int
    public var sslAlertThresholdDays: Int
    public var domainAlertThresholdDays: Int
    /// How long check_results history is kept before being pruned; 0 = keep forever.
    public var historyRetentionDays: Int
    /// CPU/SoC temperature (°C) that triggers a "running hot" alert. 0 disables it.
    public var systemTempAlertThresholdCelsius: Int
    /// Battery percentage (while unplugged) that triggers a "battery low" alert. 0 disables it.
    public var batteryLowAlertThresholdPercent: Int

    public static let defaults = AppSettings(
        notificationsEnabled: false,
        smtpEnabled: false,
        smtpRecipientEmail: "",
        smtpFrequency: "monthly",
        smtpDayOfWeek: 1,
        smtpDayOfMonth: 1,
        failureAlertThreshold: 2,
        responseTimeAlertThresholdMs: 0,
        sslAlertThresholdDays: 14,
        domainAlertThresholdDays: 30,
        historyRetentionDays: 90,
        systemTempAlertThresholdCelsius: 0,
        batteryLowAlertThresholdPercent: 0
    )
}

public struct SettingsRepository: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> AppSettings {
        try dbQueue.read { db in try Self.load(db) }
    }

    static func load(_ db: Database) throws -> AppSettings {
        let d = AppSettings.defaults
        func int(_ key: String, _ fallback: Int) throws -> Int {
            Int(try AppSettingsStore.get(db, key: key, default: String(fallback))) ?? fallback
        }
        return AppSettings(
            notificationsEnabled: try AppSettingsStore.get(db, key: "notifications_enabled", default: "0") == "1",
            smtpEnabled: try AppSettingsStore.get(db, key: "smtp_enabled", default: "0") == "1",
            smtpRecipientEmail: try AppSettingsStore.get(db, key: "smtp_recipient_email", default: d.smtpRecipientEmail),
            smtpFrequency: try AppSettingsStore.get(db, key: "smtp_frequency", default: d.smtpFrequency),
            smtpDayOfWeek: try int("smtp_day_of_week", d.smtpDayOfWeek),
            smtpDayOfMonth: try int("smtp_day_of_month", d.smtpDayOfMonth),
            failureAlertThreshold: try int("failure_alert_threshold", d.failureAlertThreshold),
            responseTimeAlertThresholdMs: try int("response_time_alert_threshold_ms", d.responseTimeAlertThresholdMs),
            sslAlertThresholdDays: try int("ssl_alert_threshold_days", d.sslAlertThresholdDays),
            domainAlertThresholdDays: try int("domain_alert_threshold_days", d.domainAlertThresholdDays),
            historyRetentionDays: try int("history_retention_days", d.historyRetentionDays),
            systemTempAlertThresholdCelsius: try int("system_temp_alert_threshold_celsius", d.systemTempAlertThresholdCelsius),
            batteryLowAlertThresholdPercent: try int("battery_low_alert_threshold_percent", d.batteryLowAlertThresholdPercent)
        )
    }

    public func update(_ settings: AppSettings) throws {
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "notifications_enabled", value: settings.notificationsEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "smtp_enabled", value: settings.smtpEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "smtp_recipient_email", value: settings.smtpRecipientEmail)
            try AppSettingsStore.set(db, key: "smtp_frequency", value: settings.smtpFrequency)
            try AppSettingsStore.set(db, key: "smtp_day_of_week", value: String(settings.smtpDayOfWeek))
            try AppSettingsStore.set(db, key: "smtp_day_of_month", value: String(settings.smtpDayOfMonth))
            try AppSettingsStore.set(db, key: "failure_alert_threshold", value: String(settings.failureAlertThreshold))
            try AppSettingsStore.set(db, key: "response_time_alert_threshold_ms", value: String(settings.responseTimeAlertThresholdMs))
            try AppSettingsStore.set(db, key: "ssl_alert_threshold_days", value: String(settings.sslAlertThresholdDays))
            try AppSettingsStore.set(db, key: "domain_alert_threshold_days", value: String(settings.domainAlertThresholdDays))
            try AppSettingsStore.set(db, key: "history_retention_days", value: String(settings.historyRetentionDays))
            try AppSettingsStore.set(db, key: "system_temp_alert_threshold_celsius", value: String(settings.systemTempAlertThresholdCelsius))
            try AppSettingsStore.set(db, key: "battery_low_alert_threshold_percent", value: String(settings.batteryLowAlertThresholdPercent))
        }
    }
}
