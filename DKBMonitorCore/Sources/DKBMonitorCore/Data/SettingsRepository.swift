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
    /// Default HTTP re-check interval (seconds) used to pre-fill new targets'
    /// own `checkIntervalSecs` — each target can still override it individually.
    public var httpCheckIntervalSecs: Int
    /// Sends every alert to a Slack/Discord/plain webhook as well as (or
    /// instead of) this Mac's notification centre — independent of
    /// `notificationsEnabled`, since the point is to reach someone who
    /// isn't sitting at this machine.
    public var webhookEnabled: Bool
    public var webhookURL: String
    /// CPU/RAM/disk percentages a monitored remote server must reach before
    /// it alerts; 0 disables that one. Only servers with `monitoringEnabled`
    /// are polled at all.
    public var remoteCPUAlertThresholdPercent: Int
    public var remoteMemoryAlertThresholdPercent: Int
    public var remoteDiskAlertThresholdPercent: Int

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
        batteryLowAlertThresholdPercent: 0,
        httpCheckIntervalSecs: 300,
        webhookEnabled: false,
        webhookURL: "",
        remoteCPUAlertThresholdPercent: 0,
        remoteMemoryAlertThresholdPercent: 0,
        remoteDiskAlertThresholdPercent: 0
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
            batteryLowAlertThresholdPercent: try int("battery_low_alert_threshold_percent", d.batteryLowAlertThresholdPercent),
            httpCheckIntervalSecs: try int("http_check_interval_secs", d.httpCheckIntervalSecs),
            webhookEnabled: try AppSettingsStore.get(db, key: "webhook_enabled", default: "0") == "1",
            webhookURL: try AppSettingsStore.get(db, key: "webhook_url", default: d.webhookURL),
            remoteCPUAlertThresholdPercent: try int("remote_cpu_alert_threshold_percent", d.remoteCPUAlertThresholdPercent),
            remoteMemoryAlertThresholdPercent: try int("remote_memory_alert_threshold_percent", d.remoteMemoryAlertThresholdPercent),
            remoteDiskAlertThresholdPercent: try int("remote_disk_alert_threshold_percent", d.remoteDiskAlertThresholdPercent)
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
            try AppSettingsStore.set(db, key: "http_check_interval_secs", value: String(settings.httpCheckIntervalSecs))
            try AppSettingsStore.set(db, key: "webhook_enabled", value: settings.webhookEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "webhook_url", value: settings.webhookURL)
            try AppSettingsStore.set(db, key: "remote_cpu_alert_threshold_percent", value: String(settings.remoteCPUAlertThresholdPercent))
            try AppSettingsStore.set(db, key: "remote_memory_alert_threshold_percent", value: String(settings.remoteMemoryAlertThresholdPercent))
            try AppSettingsStore.set(db, key: "remote_disk_alert_threshold_percent", value: String(settings.remoteDiskAlertThresholdPercent))
        }
    }
}
