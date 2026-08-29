import Foundation
import GRDB

public struct AlertState: Codable, Equatable, Sendable {
    public var targetId: Int64
    public var consecutiveFailures: Int
    public var consecutiveSlow: Int
    public var lastAlertSentAt: Date?

    public init(targetId: Int64, consecutiveFailures: Int = 0, consecutiveSlow: Int = 0, lastAlertSentAt: Date? = nil) {
        self.targetId = targetId
        self.consecutiveFailures = consecutiveFailures
        self.consecutiveSlow = consecutiveSlow
        self.lastAlertSentAt = lastAlertSentAt
    }
}

extension AlertState: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "alert_state"
    enum CodingKeys: String, CodingKey {
        case targetId = "target_id"
        case consecutiveFailures = "consecutive_failures"
        case consecutiveSlow = "consecutive_slow"
        case lastAlertSentAt = "last_alert_sent_at"
    }
}

/// `app_settings` is a plain key/value table (see AppSettingsStore) — this
/// record type is only used internally by the store, not exposed publicly.
struct AppSettingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_settings"
    var key: String
    var value: String
}
