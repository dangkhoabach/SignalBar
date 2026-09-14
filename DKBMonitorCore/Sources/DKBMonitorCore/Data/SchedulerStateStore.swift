import Foundation
import GRDB

/// Scheduler bookkeeping that isn't specific to any one target: history
/// retention cleanup, periodic-report dedupe, and system-wide (temp/battery)
/// alert active-flags. Mirrors the free functions in the Rust `scheduler.rs`
/// that read/write ad-hoc `app_settings` keys for the same purpose.
public struct SchedulerStateStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Deletes `check_results` older than `retentionDays`, at most once per
    /// calendar day (guarded by a stored last-run date) — mirrors
    /// `maybe_cleanup_history`. No-op if `retentionDays <= 0` (keep forever).
    public func cleanupHistoryIfDue(retentionDays: Int, today: Date = Date()) throws {
        guard retentionDays > 0 else { return }
        try dbQueue.write { db in
            let todayString = Self.dayFormatter.string(from: today)
            let lastCleanup = try AppSettingsStore.get(db, key: "last_history_cleanup_date", default: "")
            guard lastCleanup != todayString else { return }

            try db.execute(sql: "DELETE FROM check_results WHERE checked_at < datetime('now', ?)", arguments: ["-\(retentionDays) day"])
            try AppSettingsStore.set(db, key: "last_history_cleanup_date", value: todayString)
        }
    }

    /// True the first time a system-wide condition (temp/battery) crosses its
    /// threshold; stays true until `setAlertFlag` clears it — same
    /// "alert on transition only" shape as the per-target alerts.
    public func alertFlag(_ key: String) throws -> Bool {
        try dbQueue.read { db in try AppSettingsStore.get(db, key: key, default: "0") == "1" }
    }

    public func setAlertFlag(_ key: String, _ active: Bool) throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: key, value: active ? "1" : "0") }
    }

    // MARK: - Report dedupe

    public struct ReportPeriod: Sendable, Equatable {
        public let isDueToday: Bool
        /// Doubles as the dedupe key — its format changes with frequency, so
        /// switching frequency naturally invalidates any stale guard left
        /// over from a different cadence instead of needing separate keys.
        public let periodIdentifier: String
        public let label: String
        public let days: Int
    }

    /// Mirrors `report_period`. Exact ISO-week numbering vs. chrono's isn't
    /// load-bearing here — `periodIdentifier` only needs to change once per
    /// period and stay stable within it, which `Calendar`'s week components
    /// already guarantee.
    public static func reportPeriod(frequency: String, dayOfWeek: Int, dayOfMonth: Int, now: Date = Date()) -> ReportPeriod {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        switch frequency {
        case "daily":
            return ReportPeriod(isDueToday: true, periodIdentifier: dayFormatter.string(from: now), label: "Daily", days: 1)
        case "weekly":
            // chrono's `num_days_from_monday`: Monday = 0 ... Sunday = 6.
            let weekday = calendar.component(.weekday, from: now) // Sunday = 1 ... Saturday = 7
            let daysFromMonday = (weekday + 5) % 7
            let week = calendar.component(.weekOfYear, from: now)
            let year = calendar.component(.yearForWeekOfYear, from: now)
            return ReportPeriod(
                isDueToday: daysFromMonday == dayOfWeek,
                periodIdentifier: String(format: "%04d-W%02d", year, week),
                label: "Weekly", days: 7
            )
        default:
            let day = calendar.component(.day, from: now)
            return ReportPeriod(isDueToday: day == dayOfMonth, periodIdentifier: monthFormatter.string(from: now), label: "Monthly", days: 30)
        }
    }

    public func lastReportSentPeriod() throws -> String {
        try dbQueue.read { db in try AppSettingsStore.get(db, key: "last_report_sent_period", default: "") }
    }

    public func markReportSent(period: String) throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: "last_report_sent_period", value: period) }
    }

    /// When a send was last attempted, successful or not.
    ///
    /// `isDueToday` stays true for the whole day and `markReportSent` only
    /// runs on success, so a relay that's down turned the 15-second tick into
    /// a retry loop — on the order of 5,700 POSTs in a day, every one of them
    /// swallowed silently. Recording the attempt, not just the success, is
    /// what lets the scheduler back off.
    ///
    /// Stored as a Unix timestamp rather than a formatted date: this value is
    /// only ever compared against `Date()`, never shown, and a plain number
    /// needs no formatter (`ISO8601DateFormatter` isn't `Sendable`, so a
    /// shared static one wouldn't compile under strict concurrency anyway).
    public func lastReportAttempt() throws -> Date? {
        let raw = try dbQueue.read { db in
            try AppSettingsStore.get(db, key: "last_report_attempt_at", default: "")
        }
        guard let seconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func markReportAttempted(at date: Date = Date()) throws {
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "last_report_attempt_at", value: String(date.timeIntervalSince1970))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
