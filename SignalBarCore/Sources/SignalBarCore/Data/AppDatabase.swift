import Foundation
import GRDB

/// Opens (or creates) the app's SQLite database and keeps it migrated.
///
/// This reads the **same file** the Tauri app already used (same bundle
/// id), so `migrator` must both (a) create the
/// full schema from scratch on a brand-new install, and (b) transform an
/// existing Tauri-created DB (which predates GRDB entirely) into the same
/// end state. Both paths are exercised in `AppDatabaseTests`.
public struct AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests/previews.
    public init(inMemory: DatabaseQueue) throws {
        dbQueue = inMemory
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Mirrors db.rs::init_db exactly (including every column ever added
        // via `ensure_column`), so this step is a correct no-op against an
        // existing Tauri-created DB and a correct fresh create otherwise.
        migrator.registerMigration("v1_baselineSchema") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS targets (
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
                    sort_order INTEGER,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS check_results (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
                    checked_at TEXT NOT NULL DEFAULT (datetime('now')),
                    success INTEGER NOT NULL,
                    status_code INTEGER,
                    response_time_ms INTEGER,
                    error_message TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_check_results_target_time
                    ON check_results(target_id, checked_at DESC);

                CREATE TABLE IF NOT EXISTS ssl_status (
                    target_id INTEGER PRIMARY KEY REFERENCES targets(id) ON DELETE CASCADE,
                    expiry_date TEXT,
                    last_checked TEXT NOT NULL DEFAULT (datetime('now')),
                    last_alert_sent_at TEXT
                );

                CREATE TABLE IF NOT EXISTS domain_status (
                    target_id INTEGER PRIMARY KEY REFERENCES targets(id) ON DELETE CASCADE,
                    expiry_date TEXT,
                    last_checked TEXT NOT NULL DEFAULT (datetime('now')),
                    last_alert_sent_at TEXT
                );

                CREATE TABLE IF NOT EXISTS alert_state (
                    target_id INTEGER PRIMARY KEY REFERENCES targets(id) ON DELETE CASCADE,
                    consecutive_failures INTEGER NOT NULL DEFAULT 0,
                    consecutive_slow INTEGER NOT NULL DEFAULT 0,
                    last_alert_sent_at TEXT
                );

                CREATE TABLE IF NOT EXISTS app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)

            try db.addColumnIfMissing(table: "targets", column: "sort_order", type: "INTEGER")
            try db.execute(sql: "UPDATE targets SET sort_order = id WHERE sort_order IS NULL")

            // Best-effort, same reasoning as the Rust version: an old install
            // with pre-existing duplicate URLs shouldn't fail the whole migration.
            do {
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_targets_url_unique
                    ON targets (lower(trim(url)))
                    """)
            } catch {
                // Not fatal, but no longer silent: the comment here used to
                // claim this was logged while the block was empty, so an
                // install that quietly went without the unique index left no
                // trace of why duplicate URLs were suddenly possible.
                print("Migration: could not create idx_targets_url_unique (duplicate URLs already present?): \(error)")
            }
        }

        // Schema cleanup: replace the `paused_until = '9999-12-31...'`
        // sentinel with an explicit boolean, so every other query only ever
        // needs `paused_indefinitely OR paused_until > now` instead of also
        // remembering a magic date.
        migrator.registerMigration("v2_explicitIndefinitePause") { db in
            try db.addColumnIfMissing(table: "targets", column: "paused_indefinitely", type: "INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                UPDATE targets
                SET paused_indefinitely = 1, paused_until = NULL
                WHERE paused_until = '9999-12-31 00:00:00'
                """)
        }

        // Remote server management: `remote_server_allowlist` is the whitelist of
        // services/config paths/log paths each server permits — `value`'s
        // meaning depends on `kind`, enforced at the Domain layer
        // (RemoteCommandExecutor), not by a DB constraint. `keychain_ref`
        // points at the credential stored in Keychain (KeychainStore), never
        // the credential itself.
        migrator.registerMigration("v3_remoteServers") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS remote_servers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    host TEXT NOT NULL,
                    port INTEGER NOT NULL DEFAULT 22,
                    username TEXT NOT NULL,
                    auth_method TEXT NOT NULL,
                    keychain_ref TEXT NOT NULL,
                    group_tag TEXT,
                    -- Trust-on-first-use SSH host key pinning: NULL until the
                    -- first successful connect, which records the presented
                    -- host key's fingerprint here; every later connect must
                    -- match it (TOFUHostKeyValidator in SSHCommandRunner.swift)
                    -- or the connection is refused as a possible MITM.
                    host_key_fingerprint TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE IF NOT EXISTS remote_server_allowlist (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    remote_server_id INTEGER NOT NULL REFERENCES remote_servers(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_remote_server_allowlist_server
                    ON remote_server_allowlist(remote_server_id);

                CREATE TABLE IF NOT EXISTS remote_command_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    remote_server_id INTEGER NOT NULL REFERENCES remote_servers(id) ON DELETE CASCADE,
                    action TEXT NOT NULL,
                    params_json TEXT,
                    executed_at TEXT NOT NULL DEFAULT (datetime('now')),
                    exit_code INTEGER,
                    output_excerpt TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_remote_command_log_server_time
                    ON remote_command_log(remote_server_id, executed_at DESC);
                """)
        }

        // Resource alerting is opt-in per server, and off by default.
        //
        // Turning on a global CPU/RAM/disk threshold must not silently start
        // opening SSH connections to every server the user ever registered:
        // they were added for manual management, and putting them on a timer
        // is a different thing to agree to. The threshold says what counts as
        // too high; this column says which servers are watched at all.
        migrator.registerMigration("v4_remoteServerMonitoring") { db in
            try db.addColumnIfMissing(
                table: "remote_servers", column: "monitoring_enabled", type: "INTEGER NOT NULL DEFAULT 0"
            )
        }

        return migrator
    }
}

extension Database {
    /// Same purpose as db.rs's `ensure_column`: safe to call whether or not
    /// the column already exists, so migrations stay idempotent against a
    /// DB that's already at (or past) this point.
    func addColumnIfMissing(table: String, column: String, type: String) throws {
        let exists = try Bool.fetchOne(
            self,
            sql: "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            arguments: [table, column]
        ) ?? false
        if !exists {
            try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }
}
