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

        // Network: subnets, the devices found in them and how they were
        // found. Every table is new and prefixed `network_`, so nothing that
        // existed before is touched, and "delete all Network data" is a matter
        // of emptying these tables.
        //
        // A device is unique by MAC within its subnet; one known only by
        // address (seen through a router, no MAC) is unique by that address
        // until a MAC turns up for it. Sightings are upserted per device,
        // source and address rather than appended per scan, and IP history
        // is one row per stretch of time on an address, so neither grows with
        // the number of scans.
        migrator.registerMigration("v5_network") { db in
            try db.execute(sql: """
                CREATE TABLE network_subnets (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    cidr TEXT NOT NULL UNIQUE,
                    vlan_id INTEGER,
                    notes TEXT,
                    scan_enabled INTEGER NOT NULL DEFAULT 1,
                    scan_interval_secs INTEGER NOT NULL DEFAULT 900,
                    last_scan_at TEXT,
                    last_scan_status TEXT,
                    last_scan_mode TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE network_devices (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    subnet_id INTEGER NOT NULL REFERENCES network_subnets(id) ON DELETE CASCADE,
                    mac TEXT,
                    current_ip TEXT,
                    display_name TEXT,
                    hostname TEXT,
                    hostname_source TEXT,
                    vendor TEXT,
                    device_type TEXT NOT NULL DEFAULT 'unknown',
                    notes TEXT,
                    is_watched INTEGER NOT NULL DEFAULT 0,
                    is_ignored INTEGER NOT NULL DEFAULT 0,
                    ignore_conflicts INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL DEFAULT 'unknown',
                    missed_scans INTEGER NOT NULL DEFAULT 0,
                    vlan_id INTEGER,
                    switch_name TEXT,
                    switch_port TEXT,
                    first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
                    last_seen_at TEXT,
                    last_alert_kind TEXT,
                    last_alert_sent_at TEXT
                );
                CREATE UNIQUE INDEX idx_network_devices_mac ON network_devices(subnet_id, mac) WHERE mac IS NOT NULL;
                CREATE UNIQUE INDEX idx_network_devices_ip_only ON network_devices(subnet_id, current_ip)
                    WHERE mac IS NULL AND current_ip IS NOT NULL;
                CREATE INDEX idx_network_devices_ip ON network_devices(current_ip);

                CREATE TABLE network_ip_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id INTEGER NOT NULL REFERENCES network_devices(id) ON DELETE CASCADE,
                    ip TEXT NOT NULL,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                CREATE INDEX idx_network_ip_history_device ON network_ip_history(device_id, last_seen_at DESC);
                CREATE INDEX idx_network_ip_history_ip ON network_ip_history(ip, last_seen_at DESC);

                CREATE TABLE network_sightings (
                    device_id INTEGER NOT NULL REFERENCES network_devices(id) ON DELETE CASCADE,
                    source TEXT NOT NULL,
                    source_id INTEGER NOT NULL DEFAULT 0,
                    ip TEXT NOT NULL DEFAULT '',
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    PRIMARY KEY (device_id, source, source_id, ip)
                );

                CREATE TABLE network_sources (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    host TEXT NOT NULL DEFAULT '',
                    port INTEGER NOT NULL DEFAULT 161,
                    username TEXT,
                    snmp_version TEXT,
                    auth_protocol TEXT,
                    priv_protocol TEXT,
                    roles INTEGER NOT NULL DEFAULT 0,
                    lease_format TEXT,
                    lease_path TEXT,
                    remote_server_id INTEGER REFERENCES remote_servers(id) ON DELETE CASCADE,
                    keychain_ref TEXT NOT NULL,
                    tls_fingerprint TEXT,
                    poll_interval_secs INTEGER NOT NULL DEFAULT 300,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    consecutive_failures INTEGER NOT NULL DEFAULT 0,
                    last_poll_at TEXT,
                    last_success_at TEXT,
                    last_error TEXT,
                    sys_name TEXT,
                    sys_descr TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE network_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id INTEGER REFERENCES network_devices(id) ON DELETE CASCADE,
                    subnet_id INTEGER REFERENCES network_subnets(id) ON DELETE CASCADE,
                    source_id INTEGER REFERENCES network_sources(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    ip TEXT,
                    detail TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX idx_network_events_device ON network_events(device_id, created_at DESC);
                CREATE INDEX idx_network_events_time ON network_events(created_at DESC);
                CREATE INDEX idx_network_events_ip ON network_events(ip, kind, created_at DESC);

                CREATE TABLE network_scans (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    subnet_id INTEGER NOT NULL REFERENCES network_subnets(id) ON DELETE CASCADE,
                    trigger TEXT NOT NULL,
                    mode TEXT,
                    status TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    finished_at TEXT,
                    hosts_probed INTEGER NOT NULL DEFAULT 0,
                    hosts_found INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_network_scans_subnet ON network_scans(subnet_id, started_at DESC);

                CREATE TABLE network_dhcp_leases (
                    source_id INTEGER NOT NULL REFERENCES network_sources(id) ON DELETE CASCADE,
                    ip TEXT NOT NULL,
                    mac TEXT NOT NULL,
                    hostname TEXT,
                    ends_at TEXT,
                    is_active INTEGER NOT NULL,
                    is_reserved INTEGER NOT NULL DEFAULT 0,
                    synced_at TEXT NOT NULL,
                    PRIMARY KEY (source_id, ip)
                );
                CREATE INDEX idx_network_dhcp_leases_mac ON network_dhcp_leases(mac);

                CREATE TABLE network_snmp_interfaces (
                    source_id INTEGER NOT NULL REFERENCES network_sources(id) ON DELETE CASCADE,
                    if_index INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    alias TEXT,
                    oper_status INTEGER,
                    speed_mbps INTEGER,
                    in_octets INTEGER,
                    out_octets INTEGER,
                    in_bps REAL,
                    out_bps REAL,
                    sampled_at TEXT NOT NULL,
                    PRIMARY KEY (source_id, if_index)
                );

                CREATE TABLE network_snmp_samples (
                    source_id INTEGER NOT NULL REFERENCES network_sources(id) ON DELETE CASCADE,
                    if_index INTEGER NOT NULL,
                    in_bps REAL NOT NULL,
                    out_bps REAL NOT NULL,
                    sampled_at TEXT NOT NULL
                );
                CREATE INDEX idx_network_snmp_samples ON network_snmp_samples(source_id, if_index, sampled_at);

                CREATE TABLE network_port_results (
                    device_id INTEGER NOT NULL REFERENCES network_devices(id) ON DELETE CASCADE,
                    port INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    latency_ms REAL,
                    scanned_at TEXT NOT NULL,
                    PRIMARY KEY (device_id, port)
                );
                """)
        }

        migrator.registerMigration("v6_connection") { db in
            try db.execute(sql: """
                CREATE TABLE public_ip_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    family TEXT NOT NULL,
                    ip TEXT NOT NULL,
                    asn INTEGER,
                    holder TEXT,
                    country TEXT,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                CREATE INDEX idx_public_ip_history ON public_ip_history(family, last_seen_at);
                """)
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
