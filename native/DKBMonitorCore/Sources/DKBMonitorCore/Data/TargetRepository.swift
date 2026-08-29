import Foundation
import GRDB

public struct NewTargetInput: Sendable {
    public var name: String
    public var url: String
    public var groupTag: String?
    public var checkIntervalSecs: Int
    public var checkHTTP: Bool
    public var expectedStatus: Int
    public var checkSSL: Bool
    public var checkDomain: Bool
    public var customPath: String?
    public var expectedBodyContains: String?

    public init(
        name: String, url: String, groupTag: String? = nil, checkIntervalSecs: Int = 300,
        checkHTTP: Bool = true, expectedStatus: Int = 200, checkSSL: Bool = true, checkDomain: Bool = false,
        customPath: String? = nil, expectedBodyContains: String? = nil
    ) {
        self.name = name
        self.url = url
        self.groupTag = groupTag
        self.checkIntervalSecs = checkIntervalSecs
        self.checkHTTP = checkHTTP
        self.expectedStatus = expectedStatus
        self.checkSSL = checkSSL
        self.checkDomain = checkDomain
        self.customPath = customPath
        self.expectedBodyContains = expectedBodyContains
    }
}

public enum RepositoryError: Error, Equatable, Sendable {
    /// A target with this URL (case/whitespace-insensitive) already exists —
    /// surfaced instead of a raw SQLite constraint error, matching db.rs's
    /// `DUPLICATE_URL_ERROR` friendly message.
    case duplicateURL
}

public struct TargetRepository: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - CRUD

    public func list() throws -> [Target] {
        try dbQueue.read { db in
            try Target.order(sql: "sort_order ASC, created_at ASC").fetchAll(db)
        }
    }

    public func add(_ input: NewTargetInput) throws -> Target {
        try dbQueue.write { db in
            var target = Target(
                name: input.name,
                url: input.url,
                groupTag: HostParsing.resolveGroupTag(explicit: input.groupTag, url: input.url),
                checkIntervalSecs: input.checkIntervalSecs,
                checkHTTP: input.checkHTTP,
                expectedStatus: input.expectedStatus,
                checkSSL: input.checkSSL,
                checkDomain: input.checkDomain,
                customPath: input.customPath,
                expectedBodyContains: input.expectedBodyContains
            )
            target.sortOrder = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM targets") ?? 1
            do {
                try target.insert(db)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                throw RepositoryError.duplicateURL
            }
            return target
        }
    }

    /// `target` must already carry the fields the caller wants to keep
    /// (typically loaded via `list()`/fetched by id, then mutated) — mirrors
    /// `update_target`'s "whole row" semantics in the Rust version.
    public func update(_ target: Target) throws -> Target {
        var target = target
        target.groupTag = HostParsing.resolveGroupTag(explicit: target.groupTag, url: target.url)
        try dbQueue.write { db in
            do {
                try target.update(db)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                throw RepositoryError.duplicateURL
            }
        }
        return target
    }

    public func delete(id: Int64) throws {
        _ = try dbQueue.write { db in try Target.deleteOne(db, key: id) }
    }

    public func delete(ids: [Int64]) throws {
        try dbQueue.write { db in _ = try Target.deleteAll(db, keys: ids) }
    }

    public func setEnabled(ids: [Int64], enabled: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE targets SET enabled = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ","))) ",
                arguments: StatementArguments([enabled] + ids)
            )
        }
    }

    // MARK: - Pause / resume

    public func pause(id: Int64, until: Date?) throws {
        try dbQueue.write { db in
            if let until {
                try db.execute(sql: "UPDATE targets SET paused_until = ?, paused_indefinitely = 0 WHERE id = ?", arguments: [until, id])
            } else {
                try db.execute(sql: "UPDATE targets SET paused_until = NULL, paused_indefinitely = 1 WHERE id = ?", arguments: [id])
            }
        }
    }

    public func resume(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE targets SET paused_until = NULL, paused_indefinitely = 0 WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Ordering / grouping

    public func reorder(ids: [Int64]) throws {
        try dbQueue.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE targets SET sort_order = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    public func renameGroup(from oldName: String, to newName: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE targets SET group_tag = ? WHERE group_tag = ?", arguments: [newName, oldName])
            var order = try Self.groupOrder(db)
            order = order.map { $0 == oldName ? newName : $0 }
            try Self.setGroupOrder(db, order)
        }
    }

    public func groupOrder() throws -> [String] {
        try dbQueue.read { db in try Self.groupOrder(db) }
    }

    public func setGroupOrder(_ order: [String]) throws {
        try dbQueue.write { db in try Self.setGroupOrder(db, order) }
    }

    /// Dedupes so data left over from a prior rename bug (or a stale entry
    /// for a group whose targets all moved away) self-heals on read.
    private static func groupOrder(_ db: Database) throws -> [String] {
        let raw = try AppSettingsStore.get(db, key: "group_order", default: "[]")
        let decoded = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        var seen = Set<String>()
        return decoded.filter { seen.insert($0).inserted }
    }

    private static func setGroupOrder(_ db: Database, _ order: [String]) throws {
        var seen = Set<String>()
        let deduped = order.filter { seen.insert($0).inserted }
        let json = String(data: try JSONEncoder().encode(deduped), encoding: .utf8)!
        try AppSettingsStore.set(db, key: "group_order", value: json)
    }

    // MARK: - Read models

    public func uptimePercent(targetId: Int64, sinceModifier: String) throws -> Double? {
        try dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT AVG(success) * 100.0 FROM check_results WHERE target_id = ? AND checked_at >= datetime('now', ?)",
                arguments: [targetId, sinceModifier]
            )
        }
    }

    public func overview() throws -> [TargetOverview] {
        try dbQueue.read { db in
            let targets = try Target.order(sql: "sort_order ASC, created_at ASC").fetchAll(db)
            return try targets.map { target in
                let latest = try CheckResult
                    .filter(sql: "target_id = ?", arguments: [target.id])
                    .order(sql: "checked_at DESC")
                    .fetchOne(db)
                let ssl = try SslStatus.fetchOne(db, key: target.id)
                let domain = try DomainStatus.fetchOne(db, key: target.id)
                let uptime = try Double.fetchOne(
                    db,
                    sql: "SELECT AVG(success) * 100.0 FROM check_results WHERE target_id = ? AND checked_at >= datetime('now', '-1 day')",
                    arguments: [target.id]
                )
                return TargetOverview(target: target, latestCheck: latest, sslStatus: ssl, domainStatus: domain, uptime24hPct: uptime)
            }
        }
    }

    public func detail(targetId: Int64, historyLimit: Int = 100) throws -> TargetDetail? {
        try dbQueue.read { db in
            guard let target = try Target.fetchOne(db, key: targetId) else { return nil }
            let ssl = try SslStatus.fetchOne(db, key: targetId)
            let domain = try DomainStatus.fetchOne(db, key: targetId)
            let uptime24h = try Double.fetchOne(
                db, sql: "SELECT AVG(success) * 100.0 FROM check_results WHERE target_id = ? AND checked_at >= datetime('now', '-1 day')",
                arguments: [targetId]
            )
            let uptime7d = try Double.fetchOne(
                db, sql: "SELECT AVG(success) * 100.0 FROM check_results WHERE target_id = ? AND checked_at >= datetime('now', '-7 day')",
                arguments: [targetId]
            )
            let history = try CheckResult
                .filter(sql: "target_id = ?", arguments: [targetId])
                .order(sql: "checked_at DESC")
                .limit(historyLimit)
                .fetchAll(db)
            return TargetDetail(
                target: target, sslStatus: ssl, domainStatus: domain,
                uptime24hPct: uptime24h, uptime7dPct: uptime7d,
                history: history, incidents: history.buildIncidents()
            )
        }
    }

    /// (up count, enabled count) among enabled targets, based on each
    /// target's most recent check result — used by the menu bar summary.
    public func uptimeSummary() throws -> (up: Int, total: Int) {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COALESCE(SUM(CASE WHEN latest.success = 1 THEN 1 ELSE 0 END), 0) AS up,
                        COUNT(*) AS total
                    FROM targets t
                    LEFT JOIN (
                        SELECT cr.target_id, cr.success
                        FROM check_results cr
                        JOIN (
                            SELECT target_id, MAX(checked_at) AS max_checked
                            FROM check_results GROUP BY target_id
                        ) m ON cr.target_id = m.target_id AND cr.checked_at = m.max_checked
                    ) latest ON latest.target_id = t.id
                    WHERE t.enabled = 1
                    """
            )
            return (row?["up"] ?? 0, row?["total"] ?? 0)
        }
    }
}
