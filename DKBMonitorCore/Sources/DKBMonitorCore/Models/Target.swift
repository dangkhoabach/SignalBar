import Foundation
import GRDB

public struct Target: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var url: String
    public var groupTag: String?
    public var checkIntervalSecs: Int
    public var enabled: Bool
    public var checkHTTP: Bool
    public var expectedStatus: Int
    public var checkSSL: Bool
    public var checkDomain: Bool
    public var customPath: String?
    public var expectedBodyContains: String?
    public var lastCheckedAt: Date?
    public var pausedUntil: Date?
    public var pausedIndefinitely: Bool
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        url: String,
        groupTag: String? = nil,
        checkIntervalSecs: Int = 300,
        enabled: Bool = true,
        checkHTTP: Bool = true,
        expectedStatus: Int = 200,
        checkSSL: Bool = true,
        checkDomain: Bool = false,
        customPath: String? = nil,
        expectedBodyContains: String? = nil,
        lastCheckedAt: Date? = nil,
        pausedUntil: Date? = nil,
        pausedIndefinitely: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.groupTag = groupTag
        self.checkIntervalSecs = checkIntervalSecs
        self.enabled = enabled
        self.checkHTTP = checkHTTP
        self.expectedStatus = expectedStatus
        self.checkSSL = checkSSL
        self.checkDomain = checkDomain
        self.customPath = customPath
        self.expectedBodyContains = expectedBodyContains
        self.lastCheckedAt = lastCheckedAt
        self.pausedUntil = pausedUntil
        self.pausedIndefinitely = pausedIndefinitely
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// True while automatic checks/alerts should be skipped for this target —
    /// same precedence the scheduler and UI both need.
    public func isPaused(now: Date = Date()) -> Bool {
        if pausedIndefinitely { return true }
        if let until = pausedUntil { return until > now }
        return false
    }
}

extension Target: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "targets"

    // Raw values are the actual SQLite column names — GRDB's Codable-based
    // record conformance maps to these automatically, no hand-written
    // init(from:)/encode(to:) needed as long as this is named `CodingKeys`.
    enum CodingKeys: String, CodingKey {
        case id, name, url
        case groupTag = "group_tag"
        case checkIntervalSecs = "check_interval_secs"
        case enabled
        case checkHTTP = "check_http"
        case expectedStatus = "expected_status"
        case checkSSL = "check_ssl"
        case checkDomain = "check_domain"
        case customPath = "custom_path"
        case expectedBodyContains = "expected_body_contains"
        case lastCheckedAt = "last_checked_at"
        case pausedUntil = "paused_until"
        case pausedIndefinitely = "paused_indefinitely"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
