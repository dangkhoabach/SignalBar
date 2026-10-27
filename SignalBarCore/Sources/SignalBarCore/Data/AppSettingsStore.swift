import Foundation
import GRDB

/// Thin key/value wrapper over `app_settings` — used both for the typed
/// `AppSettings` (SettingsRepository) and ad-hoc flags (group display order,
/// alert dedupe flags, scheduler bookkeeping) the same way db.rs's
/// `get_setting`/`set_setting` free functions were used from multiple places.
public enum AppSettingsStore {
    public static func get(_ db: Database, key: String, default defaultValue: String) throws -> String {
        try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key]) ?? defaultValue
    }

    public static func set(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }
}
