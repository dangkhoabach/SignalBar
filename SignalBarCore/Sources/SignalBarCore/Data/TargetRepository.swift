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
        let url = HostParsing.normalizeURL(input.url)
        return try dbQueue.write { db in
            var target = Target(
                name: input.name,
                url: url,
                groupTag: HostParsing.resolveGroupTag(explicit: input.groupTag, url: url),
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
        target.url = HostParsing.normalizeURL(target.url)
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
        try dbQueue.read { db in try Self.overview(db) }
    }

    /// Reactive counterpart of `overview()` — emits a fresh snapshot whenever
    /// any table the query touches changes (targets/check_results/ssl_status/
    /// domain_status), instead of the UI having to poll on a timer. Was
    /// written only once there was a real list to bind it to.
    public func observeOverview() -> AsyncValueObservation<[TargetOverview]> {
        ValueObservation
            .tracking { db in try Self.overview(db) }
            .values(in: dbQueue)
    }

    /// Assembles the Overview rows in a fixed number of queries.
    ///
    /// This used to run four queries per target. `observeOverview` re-runs it
    /// on every write to any of the four tables involved, and the scheduler
    /// writes after every single check — so with the Overview open, the cost
    /// was 4×N queries firing continuously and growing with the target list.
    /// Fetching each table once and joining in memory makes it five queries
    /// no matter how many targets there are.
    ///
    /// `internal` rather than `private` only so the query-count test can call
    /// it directly; the app still reaches it through `observeOverview`.
    static func overview(_ db: Database) throws -> [TargetOverview] {
        let targets = try Target.order(sql: "sort_order ASC, created_at ASC").fetchAll(db)
        guard !targets.isEmpty else { return [] }

        let latestChecks = try latestCheckByTarget(db)
        // One row per target in both tables (`target_id` is the primary key),
        // but keyed defensively rather than with `uniqueKeysWithValues`, which
        // traps instead of resolving if that ever stops holding.
        let sslStatuses = Dictionary(
            try SslStatus.fetchAll(db).map { ($0.targetId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let domainStatuses = Dictionary(
            try DomainStatus.fetchAll(db).map { ($0.targetId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let uptimes = try uptime24hByTarget(db)

        return targets.map { target in
            let id = target.id
            return TargetOverview(
                target: target,
                latestCheck: id.flatMap { latestChecks[$0] },
                sslStatus: id.flatMap { sslStatuses[$0] },
                domainStatus: id.flatMap { domainStatuses[$0] },
                uptime24hPct: id.flatMap { uptimes[$0] }
            )
        }
    }

    /// Most recent check per target, served by `idx_check_results_target_time`.
    private static func latestCheckByTarget(_ db: Database) throws -> [Int64: CheckResult] {
        let rows = try CheckResult.fetchAll(db, sql: """
            SELECT cr.* FROM check_results cr
            JOIN (
                SELECT target_id, MAX(checked_at) AS max_checked
                FROM check_results GROUP BY target_id
            ) m ON cr.target_id = m.target_id AND cr.checked_at = m.max_checked
            """)

        var latest: [Int64: CheckResult] = [:]
        for row in rows {
            // Two checks can share a timestamp — the column stores whole
            // seconds — and the tie goes to the row inserted last, as the
            // newer of two equally-timestamped results is the current one.
            //
            // This is a deliberate change, not preserved behaviour: the old
            // `ORDER BY checked_at DESC ... fetchOne` left the tie to SQLite,
            // which walked the index and returned the *older* row. Only
            // reachable when two checks for one target land in the same
            // second, which `checkNow` next to a scheduled tick can do.
            if let existing = latest[row.targetId], (existing.id ?? 0) >= (row.id ?? 0) { continue }
            latest[row.targetId] = row
        }
        return latest
    }

    private static func uptime24hByTarget(_ db: Database) throws -> [Int64: Double] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT target_id, AVG(success) * 100.0 AS pct
            FROM check_results
            WHERE checked_at >= datetime('now', '-1 day')
            GROUP BY target_id
            """)
        return Dictionary(
            rows.map { ($0["target_id"] as Int64, $0["pct"] as Double) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func detail(targetId: Int64, historyLimit: Int = 100) throws -> TargetDetail? {
        try dbQueue.read { db in try Self.detail(db, targetId: targetId, historyLimit: historyLimit) }
    }

    /// Reactive counterpart of `detail(targetId:historyLimit:)` — same
    /// motivation as `observeOverview()`: without it, `TargetDetailView`
    /// only ever loaded once on `.onAppear` and went stale for as long as
    /// the screen stayed open, even though the scheduler kept writing fresh
    /// check results in the background.
    public func observeDetail(targetId: Int64, historyLimit: Int = 100) -> AsyncValueObservation<TargetDetail?> {
        ValueObservation
            .tracking { db in try Self.detail(db, targetId: targetId, historyLimit: historyLimit) }
            .values(in: dbQueue)
    }

    private static func detail(_ db: Database, targetId: Int64, historyLimit: Int) throws -> TargetDetail? {
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

    // MARK: - Scheduling

    /// Mirrors `scheduler.rs::tick`'s due-target query. `paused_indefinitely`
    /// is checked explicitly (the old Rust query predates that column and
    /// only checked the sentinel-date `paused_until`, which this schema no
    /// longer sets for indefinite pauses, see the schema cleanup migration).
    public func dueForHTTPCheck() throws -> [Target] {
        try dbQueue.read { db in
            try Target.fetchAll(
                db,
                sql: """
                    SELECT * FROM targets
                    WHERE enabled = 1 AND check_http = 1 AND paused_indefinitely = 0
                    AND (paused_until IS NULL OR paused_until <= datetime('now'))
                    AND (last_checked_at IS NULL
                         OR (julianday('now') - julianday(last_checked_at)) * 86400 >= check_interval_secs)
                    """
            )
        }
    }

    public func dueForSSLCheck(intervalSecs: Int) throws -> [Target] {
        try dbQueue.read { db in
            try Target.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM targets t
                    LEFT JOIN ssl_status s ON s.target_id = t.id
                    WHERE t.enabled = 1 AND t.check_ssl = 1 AND t.paused_indefinitely = 0
                    AND (t.paused_until IS NULL OR t.paused_until <= datetime('now'))
                    AND (s.last_checked IS NULL
                         OR (julianday('now') - julianday(s.last_checked)) * 86400 >= ?)
                    """,
                arguments: [intervalSecs]
            )
        }
    }

    public func dueForDomainCheck(intervalSecs: Int) throws -> [Target] {
        try dbQueue.read { db in
            try Target.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM targets t
                    LEFT JOIN domain_status d ON d.target_id = t.id
                    WHERE t.enabled = 1 AND t.check_domain = 1 AND t.paused_indefinitely = 0
                    AND (t.paused_until IS NULL OR t.paused_until <= datetime('now'))
                    AND (d.last_checked IS NULL
                         OR (julianday('now') - julianday(d.last_checked)) * 86400 >= ?)
                    """,
                arguments: [intervalSecs]
            )
        }
    }

    public struct AlertTransition: Sendable, Equatable {
        public let previousFailures: Int
        public let newFailures: Int
        public let previousSlow: Int
        public let newSlow: Int
        public let isSlow: Bool
    }

    /// Inserts the check result, bumps `last_checked_at`, and updates the
    /// consecutive-failure/slow streaks used to decide alert transitions —
    /// ports `store_result` minus the actual notification call, which the
    /// caller (Scheduler) makes based on the returned transition.
    @discardableResult
    public func storeCheckResult(targetId: Int64, outcome: HttpCheckOutcome, responseTimeAlertThresholdMs: Int) throws -> AlertTransition {
        try dbQueue.write { db in
            var result = CheckResult(
                targetId: targetId, success: outcome.success, statusCode: outcome.statusCode,
                responseTimeMs: outcome.responseTimeMs, errorMessage: outcome.errorMessage
            )
            try result.insert(db)
            try db.execute(sql: "UPDATE targets SET last_checked_at = datetime('now') WHERE id = ?", arguments: [targetId])

            let previous = try AlertState.fetchOne(db, key: targetId) ?? AlertState(targetId: targetId)
            let newFailures = outcome.success ? 0 : previous.consecutiveFailures + 1
            let isSlow = responseTimeAlertThresholdMs > 0 && outcome.success && outcome.responseTimeMs > responseTimeAlertThresholdMs
            let newSlow = isSlow ? previous.consecutiveSlow + 1 : 0

            let state = AlertState(targetId: targetId, consecutiveFailures: newFailures, consecutiveSlow: newSlow)
            try state.save(db)

            return AlertTransition(
                previousFailures: previous.consecutiveFailures, newFailures: newFailures,
                previousSlow: previous.consecutiveSlow, newSlow: newSlow, isSlow: isSlow
            )
        }
    }

    public struct ExpiryTransition: Sendable, Equatable {
        public let daysRemaining: Int?
        public let shouldAlert: Bool
    }

    @discardableResult
    public func storeSSLStatus(targetId: Int64, expiryDate: Date?, thresholdDays: Int) throws -> ExpiryTransition {
        try dbQueue.write { db in
            let previous = try SslStatus.fetchOne(db, key: targetId)
            let daysRemaining = Self.daysUntil(expiryDate)
            let shouldAlert = daysRemaining.map { $0 <= thresholdDays && !Self.alertedToday(previous?.lastAlertSentAt) } ?? false

            let status = SslStatus(
                targetId: targetId, expiryDate: expiryDate, lastChecked: Date(),
                lastAlertSentAt: shouldAlert ? Date() : previous?.lastAlertSentAt
            )
            try status.save(db)
            return ExpiryTransition(daysRemaining: daysRemaining, shouldAlert: shouldAlert)
        }
    }

    @discardableResult
    public func storeDomainStatus(targetId: Int64, expiryDate: Date?, thresholdDays: Int) throws -> ExpiryTransition {
        try dbQueue.write { db in
            let previous = try DomainStatus.fetchOne(db, key: targetId)
            let daysRemaining = Self.daysUntil(expiryDate)
            let shouldAlert = daysRemaining.map { $0 <= thresholdDays && !Self.alertedToday(previous?.lastAlertSentAt) } ?? false

            let status = DomainStatus(
                targetId: targetId, expiryDate: expiryDate, lastChecked: Date(),
                lastAlertSentAt: shouldAlert ? Date() : previous?.lastAlertSentAt
            )
            try status.save(db)
            return ExpiryTransition(daysRemaining: daysRemaining, shouldAlert: shouldAlert)
        }
    }

    private static func daysUntil(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: today, to: target).day
    }

    private static func alertedToday(_ lastAlertSentAt: Date?) -> Bool {
        guard let lastAlertSentAt else { return false }
        return Calendar(identifier: .gregorian).isDateInToday(lastAlertSentAt)
    }
}
