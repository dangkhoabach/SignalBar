use rusqlite::Connection;
use std::path::Path;

pub fn init_db(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "
        PRAGMA foreign_keys = ON;

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
            last_alert_sent_at TEXT
        );

        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        ",
    )?;

    ensure_column(&conn, "targets", "last_checked_at", "TEXT")?;
    ensure_column(&conn, "targets", "sort_order", "INTEGER")?;
    ensure_column(&conn, "ssl_status", "last_alert_sent_at", "TEXT")?;
    ensure_column(&conn, "domain_status", "last_alert_sent_at", "TEXT")?;

    // Backfill: give any row missing an explicit order its id, so existing
    // targets keep their current (creation-order) position.
    conn.execute("UPDATE targets SET sort_order = id WHERE sort_order IS NULL", [])?;

    // Case/whitespace-insensitive so "Example.com/" and "example.com" can't
    // both be added. Best-effort: an old install with pre-existing duplicate
    // URLs would fail this CREATE rather than losing data, so don't treat
    // that as fatal - just start without the constraint until it's cleaned up.
    if let Err(e) = conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_targets_url_unique ON targets (lower(trim(url)))",
        [],
    ) {
        eprintln!("Warning: could not create unique URL index (likely duplicate URLs already exist): {e}");
    }

    Ok(conn)
}

/// Adds `column` to `table` if it doesn't already exist. Lets schema
/// additions land safely against a dev/pre-release DB created by an older
/// binary, without a full migration framework.
fn ensure_column(conn: &Connection, table: &str, column: &str, sql_type: &str) -> rusqlite::Result<()> {
    let exists: bool = conn
        .prepare(&format!(
            "SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{column}'"
        ))?
        .exists([])?;
    if !exists {
        conn.execute(&format!("ALTER TABLE {table} ADD COLUMN {column} {sql_type}"), [])?;
    }
    Ok(())
}
