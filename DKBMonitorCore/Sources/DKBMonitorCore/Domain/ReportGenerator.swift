import Foundation
import GRDB

/// Plain-text periodic report content — ports `mail.rs::generate_report`
/// line for line. Pure DB read, no networking, so it's fully testable
/// headless.
public enum ReportGenerator {
    public static func generate(dbQueue: DatabaseQueue, label: String, days: Int) throws -> String {
        try dbQueue.read { db in try generate(db, label: label, days: days) }
    }

    private static func generate(_ db: Database, label: String, days: Int) throws -> String {
        let targets = try Row.fetchAll(db, sql: "SELECT id, name FROM targets ORDER BY name ASC")
        guard !targets.isEmpty else {
            return "DKB Monitor — \(label) Report\n\nNo targets configured."
        }

        let window = "-\(days) day"
        var lines = ["DKB Monitor — \(label) Report (last \(days) days)", ""]

        for row in targets {
            let id: Int64 = row["id"]
            let name: String = row["name"]

            let uptime = try Double.fetchOne(
                db, sql: "SELECT AVG(success) * 100.0 FROM check_results WHERE target_id = ? AND checked_at >= datetime('now', ?)",
                arguments: [id, window]
            )
            let downCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM check_results WHERE target_id = ? AND success = 0 AND checked_at >= datetime('now', ?)",
                arguments: [id, window]
            ) ?? 0
            let sslExpiry = try Date.fetchOne(db, sql: "SELECT expiry_date FROM ssl_status WHERE target_id = ?", arguments: [id])
            let domainExpiry = try Date.fetchOne(db, sql: "SELECT expiry_date FROM domain_status WHERE target_id = ?", arguments: [id])

            let uptimeStr = uptime.map { String(format: "%.1f%%", $0) } ?? "n/a"
            var line = "- \(name): \(uptimeStr) uptime, \(downCount) failed checks"
            if let sslExpiry { line += ", SSL expires \(Self.dayFormatter.string(from: sslExpiry))" }
            if let domainExpiry { line += ", domain expires \(Self.dayFormatter.string(from: domainExpiry))" }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
