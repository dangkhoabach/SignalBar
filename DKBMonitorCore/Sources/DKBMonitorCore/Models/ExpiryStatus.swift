import Foundation
import GRDB

// `ssl_status` and `domain_status` share the same 4 columns and the same
// alert-dedupe logic, only the table differs — kept as two small duplicated
// types rather than a clever shared wrapper, since GRDB ties a record type
// to exactly one `databaseTableName`.

public struct SslStatus: Codable, Equatable, Sendable {
    public var targetId: Int64
    public var expiryDate: Date?
    public var lastChecked: Date
    public var lastAlertSentAt: Date?

    public init(targetId: Int64, expiryDate: Date? = nil, lastChecked: Date = Date(), lastAlertSentAt: Date? = nil) {
        self.targetId = targetId
        self.expiryDate = expiryDate
        self.lastChecked = lastChecked
        self.lastAlertSentAt = lastAlertSentAt
    }
}

extension SslStatus: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ssl_status"
    enum CodingKeys: String, CodingKey {
        case targetId = "target_id"
        case expiryDate = "expiry_date"
        case lastChecked = "last_checked"
        case lastAlertSentAt = "last_alert_sent_at"
    }
}

public struct DomainStatus: Codable, Equatable, Sendable {
    public var targetId: Int64
    public var expiryDate: Date?
    public var lastChecked: Date
    public var lastAlertSentAt: Date?

    public init(targetId: Int64, expiryDate: Date? = nil, lastChecked: Date = Date(), lastAlertSentAt: Date? = nil) {
        self.targetId = targetId
        self.expiryDate = expiryDate
        self.lastChecked = lastChecked
        self.lastAlertSentAt = lastAlertSentAt
    }
}

extension DomainStatus: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "domain_status"
    enum CodingKeys: String, CodingKey {
        case targetId = "target_id"
        case expiryDate = "expiry_date"
        case lastChecked = "last_checked"
        case lastAlertSentAt = "last_alert_sent_at"
    }
}
