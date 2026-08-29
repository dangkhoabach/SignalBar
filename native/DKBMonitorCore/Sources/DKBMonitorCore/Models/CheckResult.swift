import Foundation
import GRDB

public struct CheckResult: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var targetId: Int64
    public var checkedAt: Date
    public var success: Bool
    public var statusCode: Int?
    public var responseTimeMs: Int?
    public var errorMessage: String?

    public init(
        id: Int64? = nil,
        targetId: Int64,
        checkedAt: Date = Date(),
        success: Bool,
        statusCode: Int? = nil,
        responseTimeMs: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.targetId = targetId
        self.checkedAt = checkedAt
        self.success = success
        self.statusCode = statusCode
        self.responseTimeMs = responseTimeMs
        self.errorMessage = errorMessage
    }
}

extension CheckResult: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "check_results"

    enum CodingKeys: String, CodingKey {
        case id
        case targetId = "target_id"
        case checkedAt = "checked_at"
        case success
        case statusCode = "status_code"
        case responseTimeMs = "response_time_ms"
        case errorMessage = "error_message"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
