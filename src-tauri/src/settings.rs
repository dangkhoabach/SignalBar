use crate::mail;
use crate::AppState;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use tauri::State;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AppSettings {
    pub notifications_enabled: bool,
    pub smtp_enabled: bool,
    pub smtp_recipient_email: String,
    /// "daily" | "weekly" | "monthly"
    pub smtp_frequency: String,
    pub smtp_day_of_week: i64,
    pub smtp_day_of_month: i64,
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
    /// CPU/SoC temperature (°C) that triggers a "running hot" alert. 0 disables it.
    pub system_temp_alert_threshold_celsius: i64,
    /// Battery percentage (while unplugged) that triggers a "battery low" alert. 0 disables it.
    pub battery_low_alert_threshold_percent: i64,
}

#[derive(Debug, Deserialize)]
pub struct UpdateSettingsInput {
    pub notifications_enabled: bool,
    pub smtp_enabled: bool,
    pub smtp_recipient_email: String,
    pub smtp_frequency: String,
    pub smtp_day_of_week: i64,
    pub smtp_day_of_month: i64,
    pub failure_alert_threshold: i64,
    pub response_time_alert_threshold_ms: i64,
    pub ssl_alert_threshold_days: i64,
    pub domain_alert_threshold_days: i64,
    pub history_retention_days: i64,
    pub system_temp_alert_threshold_celsius: i64,
    pub battery_low_alert_threshold_percent: i64,
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
        notifications_enabled: get_setting(conn, "notifications_enabled", "0") == "1",
        smtp_enabled: get_setting(conn, "smtp_enabled", "0") == "1",
        smtp_recipient_email: get_setting(conn, "smtp_recipient_email", ""),
        smtp_frequency: get_setting(conn, "smtp_frequency", "monthly"),
        smtp_day_of_week: get_setting(conn, "smtp_day_of_week", "1").parse().unwrap_or(1),
        smtp_day_of_month: get_setting(conn, "smtp_day_of_month", "1").parse().unwrap_or(1),
        failure_alert_threshold: get_setting(conn, "failure_alert_threshold", "2").parse().unwrap_or(2),
        response_time_alert_threshold_ms: get_setting(conn, "response_time_alert_threshold_ms", "0")
            .parse()
            .unwrap_or(0),
        ssl_alert_threshold_days: get_setting(conn, "ssl_alert_threshold_days", "14").parse().unwrap_or(14),
        domain_alert_threshold_days: get_setting(conn, "domain_alert_threshold_days", "30").parse().unwrap_or(30),
        history_retention_days: get_setting(conn, "history_retention_days", "90").parse().unwrap_or(90),
        system_temp_alert_threshold_celsius: get_setting(conn, "system_temp_alert_threshold_celsius", "0")
            .parse()
            .unwrap_or(0),
        battery_low_alert_threshold_percent: get_setting(conn, "battery_low_alert_threshold_percent", "0")
            .parse()
            .unwrap_or(0),
    }
}

pub fn notifications_enabled(conn: &Connection) -> bool {
    get_setting(conn, "notifications_enabled", "0") == "1"
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
    set_setting(
        &conn,
        "system_temp_alert_threshold_celsius",
        &settings.system_temp_alert_threshold_celsius.to_string(),
    )
    .map_err(|e| e.to_string())?;
    set_setting(
        &conn,
        "battery_low_alert_threshold_percent",
        &settings.battery_low_alert_threshold_percent.to_string(),
    )
    .map_err(|e| e.to_string())?;
    Ok(load_settings(&conn))
}

#[tauri::command]
pub fn get_group_order(state: State<AppState>) -> Result<Vec<String>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let raw = get_setting(&conn, "group_order", "[]");
    let order: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
    // Self-heals data left over from a prior version's rename_group bug,
    // which could persist the same group name twice.
    let mut seen = std::collections::HashSet::new();
    Ok(order.into_iter().filter(|name| seen.insert(name.clone())).collect())
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

    if settings.smtp_recipient_email.is_empty() {
        return Err("Chưa nhập email nhận thông báo".to_string());
    }
    mail::send_email_via_relay(
        &state.http_client,
        &settings.smtp_recipient_email,
        "DKB Monitor — Test email",
        "Đây là email test từ DKB Monitor. Cấu hình email đang hoạt động bình thường.",
    )
    .await
}
