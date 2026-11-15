import Foundation
import GRDB

/// One public address this Mac had, from when it was first seen until it was last confirmed.
public struct PublicIPRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var family: AddressFamily
    public var ip: String
    public var asn: Int?
    public var holder: String?
    public var country: String?
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

extension PublicIPRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "public_ip_history"

    enum CodingKeys: String, CodingKey {
        case id, family, ip, asn, holder, country
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ConnectionRepository: Sendable {
    static let historyLimit = 500

    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Notes that `address` is the public address now. Returns the record it
    /// replaced when the address changed; `nil` when it's the same as before
    /// or the first one ever seen for its family.
    @discardableResult
    public func record(_ address: PublicAddress, at date: Date = Date()) throws -> PublicIPRecord? {
        try dbQueue.write { db in
            let latest = try PublicIPRecord
                .filter(Column("family") == address.family.rawValue)
                .order(Column("last_seen_at").desc, Column("id").desc)
                .fetchOne(db)
            if var current = latest, current.ip == address.ip {
                current.lastSeenAt = date
                current.asn = address.asn ?? current.asn
                current.holder = address.holder ?? current.holder
                current.country = address.country ?? current.country
                try current.update(db)
                return nil
            }
            var record = PublicIPRecord(family: address.family, ip: address.ip, asn: address.asn, holder: address.holder,
                                        country: address.country, firstSeenAt: date, lastSeenAt: date)
            try record.insert(db)
            try db.execute(sql: """
                DELETE FROM public_ip_history WHERE id NOT IN
                    (SELECT id FROM public_ip_history ORDER BY last_seen_at DESC, id DESC LIMIT ?)
                """, arguments: [Self.historyLimit])
            return latest
        }
    }

    /// Newest first.
    public func history(limit: Int = 100) throws -> [PublicIPRecord] {
        try dbQueue.read { db in
            try PublicIPRecord.order(Column("last_seen_at").desc, Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    public func clearHistory() throws {
        _ = try dbQueue.write { db in try PublicIPRecord.deleteAll(db) }
    }
}
