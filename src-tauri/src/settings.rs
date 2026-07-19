use crate::mail;
use crate::AppState;
use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::State;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AppSettings {
    pub notifications_enabled: bool,
    pub smtp_enabled: bool,
    pub smtp_host: String,
    pub smtp_port: i64,
    pub smtp_sender_email: String,
    pub smtp_recipient_email: String,
    /// "daily" | "weekly" | "monthly"
    pub smtp_frequency: String,
    pub smtp_day_of_week: i64,
    pub smtp_day_of_month: i64,
    pub has_smtp_password: bool,
    /// Consecutive HTTP failures before a "target is down" alert fires.
    pub failure_alert_threshold: i64,
    /// Response time (ms) a successful check must exceed, for
    /// `failure_alert_threshold` consecutive checks, before a "slow" alert
    /// fires. 0 disables this alert.
    pub response_time_alert_threshold_ms: i64,
    pub ssl_alert_threshold_days: i64,
    pub domain_alert_threshold_days: i64,
    /// How long check_results history is kept before being pruned; 0 = keep forever.
    pub history_retention_days: i64,
}

#[derive(Debug, Deserialize)]
pub struct UpdateSettingsInput {
    pub notifications_enabled: bool,
    pub smtp_enabled: bool,
    pub smtp_host: String,
    pub smtp_port: i64,
    pub smtp_sender_email: String,
    pub smtp_recipient_email: String,
    pub smtp_frequency: String,
    pub smtp_day_of_week: i64,
    pub smtp_day_of_month: i64,
    pub failure_alert_threshold: i64,
    pub response_time_alert_threshold_ms: i64,
    pub ssl_alert_threshold_days: i64,
    pub domain_alert_threshold_days: i64,
    pub history_retention_days: i64,
}

fn get_setting(conn: &Connection, key: &str, default: &str) -> String {
    conn.query_row("SELECT value FROM app_settings WHERE key = ?1", params![key], |row| row.get(0))
        .unwrap_or_else(|_| default.to_string())
}

fn set_setting(conn: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = ?2",
        params![key, value],
    )?;
    Ok(())
}

pub fn load_settings(conn: &Connection) -> AppSettings {
    AppSettings {
        notifications_enabled: get_setting(conn, "notifications_enabled", "1") == "1",
        smtp_enabled: get_setting(conn, "smtp_enabled", "0") == "1",
        smtp_host: get_setting(conn, "smtp_host", "smtp.gmail.com"),
        smtp_port: get_setting(conn, "smtp_port", "587").parse().unwrap_or(587),
        smtp_sender_email: get_setting(conn, "smtp_sender_email", ""),
        smtp_recipient_email: get_setting(conn, "smtp_recipient_email", ""),
        smtp_frequency: get_setting(conn, "smtp_frequency", "monthly"),
        smtp_day_of_week: get_setting(conn, "smtp_day_of_week", "1").parse().unwrap_or(1),
        smtp_day_of_month: get_setting(conn, "smtp_day_of_month", "1").parse().unwrap_or(1),
        has_smtp_password: !get_setting(conn, "smtp_password", "").is_empty(),
        failure_alert_threshold: get_setting(conn, "failure_alert_threshold", "2").parse().unwrap_or(2),
        response_time_alert_threshold_ms: get_setting(conn, "response_time_alert_threshold_ms", "0")
            .parse()
            .unwrap_or(0),
        ssl_alert_threshold_days: get_setting(conn, "ssl_alert_threshold_days", "14").parse().unwrap_or(14),
        domain_alert_threshold_days: get_setting(conn, "domain_alert_threshold_days", "30").parse().unwrap_or(30),
        history_retention_days: get_setting(conn, "history_retention_days", "90").parse().unwrap_or(90),
    }
}

pub fn notifications_enabled(conn: &Connection) -> bool {
    get_setting(conn, "notifications_enabled", "1") == "1"
}

/// Derives a stable local key from a fixed app salt plus the OS username.
/// This is deliberately not "real" secret management (there's no secure
/// enclave backing it — anyone with read access to this machine's files
/// could re-derive it), but it keeps the password out of plain view in the
/// SQLite file, which is what actually matters for a personal single-user
/// tool. See `smtp_password`'s doc comment for why this isn't in Keychain.
fn derive_key() -> Key<Aes256Gcm> {
    let user = std::env::var("USER").unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(b"dkb-monitor-local-v1:");
    hasher.update(user.as_bytes());
    let hash = hasher.finalize();
    *Key::<Aes256Gcm>::from_slice(&hash)
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

fn encrypt_secret(plaintext: &str) -> Option<String> {
    let cipher = Aes256Gcm::new(&derive_key());
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ciphertext = cipher.encrypt(&nonce, plaintext.as_bytes()).ok()?;
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&ciphertext);
    Some(to_hex(&combined))
}

fn decrypt_secret(stored: &str) -> Option<String> {
    let combined = from_hex(stored)?;
    if combined.len() < 12 {
        return None;
    }
    let (nonce_bytes, ciphertext) = combined.split_at(12);
    let cipher = Aes256Gcm::new(&derive_key());
    let plaintext = cipher.decrypt(Nonce::from_slice(nonce_bytes), ciphertext).ok()?;
    String::from_utf8(plaintext).ok()
}

/// Stored (encrypted) directly in the app's own SQLite database rather than
/// the macOS Keychain: ad-hoc-signed (no stable Developer ID) apps don't get
/// a code signature macOS trusts consistently across separate launches, so
/// Keychain writes made in one launch silently become unreadable in the
/// next — confirmed by writing then reading back in two separate launches
/// of an unrelated minimal test app, which failed the same way. This is a
/// personal, local-only tool, so a DB-stored password (still never leaves
/// this machine) is an acceptable trade-off for actually working.
pub fn smtp_password(conn: &Connection) -> Option<String> {
    let raw = get_setting(conn, "smtp_password", "");
    if raw.is_empty() {
        None
    } else {
        decrypt_secret(&raw)
    }
}

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Result<AppSettings, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    Ok(load_settings(&conn))
}

#[tauri::command]
pub fn update_settings(state: State<AppState>, settings: UpdateSettingsInput) -> Result<AppSettings, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    set_setting(&conn, "notifications_enabled", if settings.notifications_enabled { "1" } else { "0" })
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_enabled", if settings.smtp_enabled { "1" } else { "0" })
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_host", &settings.smtp_host).map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_port", &settings.smtp_port.to_string()).map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_sender_email", &settings.smtp_sender_email).map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_recipient_email", &settings.smtp_recipient_email).map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_frequency", &settings.smtp_frequency).map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_day_of_week", &settings.smtp_day_of_week.to_string())
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_day_of_month", &settings.smtp_day_of_month.to_string())
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "failure_alert_threshold", &settings.failure_alert_threshold.to_string())
        .map_err(|e| e.to_string())?;
    set_setting(
        &conn,
        "response_time_alert_threshold_ms",
        &settings.response_time_alert_threshold_ms.to_string(),
    )
    .map_err(|e| e.to_string())?;
    set_setting(&conn, "ssl_alert_threshold_days", &settings.ssl_alert_threshold_days.to_string())
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "domain_alert_threshold_days", &settings.domain_alert_threshold_days.to_string())
        .map_err(|e| e.to_string())?;
    set_setting(&conn, "history_retention_days", &settings.history_retention_days.to_string())
        .map_err(|e| e.to_string())?;
    Ok(load_settings(&conn))
}

#[tauri::command]
pub fn save_smtp_password(state: State<AppState>, password: String) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let encrypted = encrypt_secret(&password).ok_or("failed to encrypt password")?;
    set_setting(&conn, "smtp_password", &encrypted).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn clear_smtp_password(state: State<AppState>) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    set_setting(&conn, "smtp_password", "").map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_group_order(state: State<AppState>) -> Result<Vec<String>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let raw = get_setting(&conn, "group_order", "[]");
    Ok(serde_json::from_str(&raw).unwrap_or_default())
}

#[tauri::command]
pub fn set_group_order(state: State<AppState>, order: Vec<String>) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let raw = serde_json::to_string(&order).map_err(|e| e.to_string())?;
    set_setting(&conn, "group_order", &raw).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn send_test_email(state: State<'_, AppState>) -> Result<(), String> {
    let (settings, password) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        (load_settings(&conn), smtp_password(&conn))
    };
    let password = password.ok_or("Chưa cấu hình app password")?;
    mail::send_email(
        &settings,
        &password,
        "DKB Monitor — Test email",
        "Đây là email test từ DKB Monitor. Cấu hình SMTP hoạt động bình thường.",
    )
    .await
}
