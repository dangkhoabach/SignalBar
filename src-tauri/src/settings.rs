use crate::mail;
use crate::AppState;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use tauri::State;

const KEYRING_SERVICE: &str = "com.dangkhoabach.dkb-monitor";
const KEYRING_ACCOUNT: &str = "smtp-app-password";

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
        has_smtp_password: keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .and_then(|e| e.get_password())
            .is_ok(),
    }
}

pub fn notifications_enabled(conn: &Connection) -> bool {
    get_setting(conn, "notifications_enabled", "1") == "1"
}

pub fn smtp_password() -> Option<String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .ok()?
        .get_password()
        .ok()
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
    Ok(load_settings(&conn))
}

#[tauri::command]
pub fn save_smtp_password(password: String) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT).map_err(|e| e.to_string())?;
    entry.set_password(&password).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn clear_smtp_password() -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
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
    let settings = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        load_settings(&conn)
    };
    let password = smtp_password().ok_or("Chưa cấu hình app password")?;
    mail::send_email(
        &settings,
        &password,
        "DKB Monitor — Test email",
        "Đây là email test từ DKB Monitor. Cấu hình SMTP hoạt động bình thường.",
    )
    .await
}
