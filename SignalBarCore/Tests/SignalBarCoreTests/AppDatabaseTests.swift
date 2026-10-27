import Foundation
import GRDB
import Testing
@testable import SignalBarCore

@Suite struct AppDatabaseTests {
    @Test func freshDatabaseGetsFullSchema() throws {
        let db = try AppDatabase(inMemory: DatabaseQueue())
        let targets = try TargetRepository(dbQueue: db.dbQueue).list()
        #expect(targets.isEmpty)
    }

    @Test func migratingIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(inMemory: queue)
        // Running the migrator again against an already-migrated DB must not
        // throw — this is the path a real launch takes every time it opens
        // the (already migrated, in a previous launch) production DB.
        _ = try AppDatabase(inMemory: queue)
    }

    /// Simulates opening a real DB created by the Tauri app (see db.rs) —
    /// pre-dates GRDB entirely, uses the sentinel-date pause representation.
    @Test func migratesExistingTauriSchema() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE targets (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    group_tag TEXT,
                    check_interval_secs INTEGER NOT NULL DEFAULT 300,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    check_http INTEGER NOT NULL DEFAULT 1,
                    expected_status INTEGER NOT NULL DEFAULT 200,
                    check_ssl INTEGER NOT NULL DEFAULT 1,
                    check_domain INTEGER NOT NULL DEFAULT 0,
                    custom_path TEXT,
                    expected_body_contains TEXT,
                    last_checked_at TEXT,
                    paused_until TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE check_results (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_id INTEGER NOT NULL,
                    checked_at TEXT NOT NULL DEFAULT (datetime('now')),
                    success INTEGER NOT NULL,
                    status_code INTEGER,
                    response_time_ms INTEGER,
                    error_message TEXT
                );
                CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            // sort_order deliberately omitted, like a pre-`ensure_column` DB.
            try db.execute(
                sql: "INSERT INTO targets (name, url, paused_until) VALUES (?, ?, ?)",
                arguments: ["Indefinitely paused", "https://example.com", "9999-12-31 00:00:00"]
            )
            try db.execute(
                sql: "INSERT INTO targets (name, url, paused_until) VALUES (?, ?, ?)",
                arguments: ["Not paused", "https://example.org", nil as String?]
            )
        }

        let app = try AppDatabase(inMemory: queue)
        let targets = try TargetRepository(dbQueue: app.dbQueue).list()

        let indefinite = try #require(targets.first { $0.name == "Indefinitely paused" })
        #expect(indefinite.pausedIndefinitely)
        #expect(indefinite.pausedUntil == nil)
        #expect(indefinite.isPaused())

        let notPaused = try #require(targets.first { $0.name == "Not paused" })
        #expect(!notPaused.pausedIndefinitely)
        #expect(!notPaused.isPaused())

        // sort_order must have been backfilled from id, and every target must be there.
        #expect(Set(targets.map(\.sortOrder)) == Set(targets.compactMap { $0.id.map(Int.init) }))
    }
}
