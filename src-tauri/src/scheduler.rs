use crate::expiry_check;
use crate::mail;
use crate::models::Target;
use crate::settings;
use crate::AppState;
use rusqlite::{params, OptionalExtension};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

const TICK_INTERVAL_SECS: u64 = 15;
const HTTP_TIMEOUT_SECS: u64 = 10;
const EXPIRY_CHECK_INTERVAL_SECS: i64 = 86_400; // SSL/domain expiry rarely changes; once a day is enough.
const FAILURE_ALERT_THRESHOLD: i64 = 2;
const SSL_ALERT_THRESHOLD_DAYS: i64 = 14;
const DOMAIN_ALERT_THRESHOLD_DAYS: i64 = 30;
const TRAY_ID: &str = "main-tray";

pub fn spawn(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(TICK_INTERVAL_SECS));
        loop {
            interval.tick().await;
            if let Err(err) = tick(&app).await {
                eprintln!("scheduler tick error: {err}");
            }
        }
    });
}

async fn tick(app: &AppHandle) -> Result<(), String> {
    let due_targets = {
        let state = app.state::<AppState>();
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                "SELECT * FROM targets
                 WHERE enabled = 1 AND check_http = 1
                 AND (last_checked_at IS NULL
                      OR (julianday('now') - julianday(last_checked_at)) * 86400 >= check_interval_secs)",
            )
            .map_err(|e| e.to_string())?;
        let targets = stmt
            .query_map([], row_to_target)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        targets
    };

    let mut any_updated = false;

    if !due_targets.is_empty() {
        let state = app.state::<AppState>();
        let client = state.http_client.clone();
        let mut handles = Vec::with_capacity(due_targets.len());
        for target in due_targets {
            let client = client.clone();
            handles.push(tokio::spawn(async move { run_check(&client, target).await }));
        }

        for handle in handles {
            if let Ok(outcome) = handle.await {
                store_result(app, &outcome)?;
                any_updated = true;
            }
        }
    }

    if run_expiry_checks(app).await? {
        any_updated = true;
    }

    if any_updated {
        let _ = app.emit("overview-updated", ());
    }

    update_tray_status(app)?;
    maybe_send_monthly_report(app).await;

    Ok(())
}

async fn maybe_send_monthly_report(app: &AppHandle) {
    let (should_send, report_settings) = {
        let state = app.state::<AppState>();
        let Ok(conn) = state.db.lock() else { return };
        let s = settings::load_settings(&conn);

        if !s.smtp_enabled || !s.has_smtp_password {
            return;
        }

        let today = chrono::Utc::now();
        let current_month = today.format("%Y-%m").to_string();
        let last_sent = conn
            .query_row(
                "SELECT value FROM app_settings WHERE key = 'last_report_sent_month'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap_or_default();

        use chrono::Datelike;
        let due = today.day() as i64 == s.smtp_day_of_month && last_sent != current_month;
        (due, s)
    };

    if !should_send {
        return;
    }

    let Some(password) = settings::smtp_password() else { return };

    let state = app.state::<AppState>();
    let body = {
        let Ok(conn) = state.db.lock() else { return };
        match mail::generate_monthly_report(&conn) {
            Ok(b) => b,
            Err(err) => {
                eprintln!("monthly report generation error: {err}");
                return;
            }
        }
    };

    match mail::send_email(&report_settings, &password, "DKB Monitor — Monthly Report", &body).await {
        Ok(()) => {
            if let Ok(conn) = state.db.lock() {
                let current_month = chrono::Utc::now().format("%Y-%m").to_string();
                let _ = conn.execute(
                    "INSERT INTO app_settings (key, value) VALUES ('last_report_sent_month', ?1)
                     ON CONFLICT(key) DO UPDATE SET value = ?1",
                    params![current_month],
                );
            }
        }
        Err(err) => eprintln!("monthly report send error: {err}"),
    }
}

async fn run_expiry_checks(app: &AppHandle) -> Result<bool, String> {
    let (ssl_due, domain_due) = {
        let state = app.state::<AppState>();
        let conn = state.db.lock().map_err(|e| e.to_string())?;

        let mut ssl_stmt = conn
            .prepare(
                "SELECT t.* FROM targets t
                 LEFT JOIN ssl_status s ON s.target_id = t.id
                 WHERE t.enabled = 1 AND t.check_ssl = 1
                 AND (s.last_checked IS NULL
                      OR (julianday('now') - julianday(s.last_checked)) * 86400 >= ?1)",
            )
            .map_err(|e| e.to_string())?;
        let ssl_due = ssl_stmt
            .query_map(params![EXPIRY_CHECK_INTERVAL_SECS], row_to_target)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;

        let mut domain_stmt = conn
            .prepare(
                "SELECT t.* FROM targets t
                 LEFT JOIN domain_status d ON d.target_id = t.id
                 WHERE t.enabled = 1 AND t.check_domain = 1
                 AND (d.last_checked IS NULL
                      OR (julianday('now') - julianday(d.last_checked)) * 86400 >= ?1)",
            )
            .map_err(|e| e.to_string())?;
        let domain_due = domain_stmt
            .query_map(params![EXPIRY_CHECK_INTERVAL_SECS], row_to_target)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;

        (ssl_due, domain_due)
    };

    let mut updated = false;

    for target in ssl_due {
        if let Some(host) = expiry_check::extract_host(&target.url) {
            let expiry = expiry_check::check_ssl_expiry(&host).await.unwrap_or(None);
            store_ssl_status(app, &target, expiry)?;
            updated = true;
        }
    }

    for target in domain_due {
        if let Some(host) = expiry_check::extract_host(&target.url) {
            let domain = expiry_check::extract_registrable_domain(&host);
            let expiry = expiry_check::check_domain_expiry(&domain).await.unwrap_or(None);
            store_domain_status(app, &target, expiry)?;
            updated = true;
        }
    }

    Ok(updated)
}

fn days_until(date: &Option<String>) -> Option<i64> {
    let date = date.as_ref()?;
    let target_date = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()?;
    let today = chrono::Utc::now().date_naive();
    Some((target_date - today).num_days())
}

fn alerted_today(last_alert_sent_at: &Option<String>) -> bool {
    let today = chrono::Utc::now().date_naive().to_string();
    last_alert_sent_at
        .as_ref()
        .map(|ts| ts.starts_with(&today))
        .unwrap_or(false)
}

fn store_ssl_status(app: &AppHandle, target: &Target, expiry_date: Option<String>) -> Result<(), String> {
    let state = app.state::<AppState>();
    let conn = state.db.lock().map_err(|e| e.to_string())?;

    let previous_alert: Option<String> = conn
        .query_row(
            "SELECT last_alert_sent_at FROM ssl_status WHERE target_id = ?1",
            params![target.id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .flatten();

    let days_remaining = days_until(&expiry_date);
    let should_alert = days_remaining
        .map(|d| d <= SSL_ALERT_THRESHOLD_DAYS && !alerted_today(&previous_alert))
        .unwrap_or(false);

    let alert_clause = if should_alert { ", last_alert_sent_at = datetime('now')" } else { "" };
    let insert_alert_col = if should_alert { ", last_alert_sent_at" } else { "" };
    let insert_alert_val = if should_alert { ", datetime('now')" } else { "" };

    conn.execute(
        &format!(
            "INSERT INTO ssl_status (target_id, expiry_date, last_checked{insert_alert_col})
             VALUES (?1, ?2, datetime('now'){insert_alert_val})
             ON CONFLICT(target_id) DO UPDATE SET expiry_date = ?2, last_checked = datetime('now'){alert_clause}"
        ),
        params![target.id, expiry_date],
    )
    .map_err(|e| e.to_string())?;

    drop(conn);

    if should_alert {
        if let Some(days) = days_remaining {
            notify(app, &format!("SSL sắp hết hạn: {}", target.name), &format!("Còn {days} ngày"));
        }
    }

    Ok(())
}

fn store_domain_status(app: &AppHandle, target: &Target, expiry_date: Option<String>) -> Result<(), String> {
    let state = app.state::<AppState>();
    let conn = state.db.lock().map_err(|e| e.to_string())?;

    let previous_alert: Option<String> = conn
        .query_row(
            "SELECT last_alert_sent_at FROM domain_status WHERE target_id = ?1",
            params![target.id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .flatten();

    let days_remaining = days_until(&expiry_date);
    let should_alert = days_remaining
        .map(|d| d <= DOMAIN_ALERT_THRESHOLD_DAYS && !alerted_today(&previous_alert))
        .unwrap_or(false);

    let alert_clause = if should_alert { ", last_alert_sent_at = datetime('now')" } else { "" };
    let insert_alert_col = if should_alert { ", last_alert_sent_at" } else { "" };
    let insert_alert_val = if should_alert { ", datetime('now')" } else { "" };

    conn.execute(
        &format!(
            "INSERT INTO domain_status (target_id, expiry_date, last_checked{insert_alert_col})
             VALUES (?1, ?2, datetime('now'){insert_alert_val})
             ON CONFLICT(target_id) DO UPDATE SET expiry_date = ?2, last_checked = datetime('now'){alert_clause}"
        ),
        params![target.id, expiry_date],
    )
    .map_err(|e| e.to_string())?;

    drop(conn);

    if should_alert {
        if let Some(days) = days_remaining {
            notify(app, &format!("Domain sắp hết hạn: {}", target.name), &format!("Còn {days} ngày"));
        }
    }

    Ok(())
}

struct CheckOutcome {
    target_id: i64,
    target_name: String,
    success: bool,
    status_code: Option<i64>,
    response_time_ms: i64,
    error_message: Option<String>,
}

async fn run_check(client: &reqwest::Client, target: Target) -> CheckOutcome {
    let url = match &target.custom_path {
        Some(path) if !path.is_empty() => format!(
            "{}{}{}",
            target.url.trim_end_matches('/'),
            if path.starts_with('/') { "" } else { "/" },
            path
        ),
        _ => target.url.clone(),
    };

    let started = Instant::now();
    let result = client
        .get(&url)
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .send()
        .await;
    let elapsed_ms = started.elapsed().as_millis() as i64;

    match result {
        Ok(response) => {
            let status_code = response.status().as_u16() as i64;
            let status_ok = status_code == target.expected_status;

            let body_ok = match &target.expected_body_contains {
                Some(needle) if !needle.is_empty() => response
                    .text()
                    .await
                    .map(|body| body.contains(needle.as_str()))
                    .unwrap_or(false),
                _ => true,
            };

            CheckOutcome {
                target_id: target.id,
                target_name: target.name.clone(),
                success: status_ok && body_ok,
                status_code: Some(status_code),
                response_time_ms: elapsed_ms,
                error_message: if status_ok && body_ok {
                    None
                } else if !status_ok {
                    Some(format!("Expected status {}, got {}", target.expected_status, status_code))
                } else {
                    Some("Response body did not contain expected text".to_string())
                },
            }
        }
        Err(err) => CheckOutcome {
            target_id: target.id,
            target_name: target.name.clone(),
            success: false,
            status_code: None,
            response_time_ms: elapsed_ms,
            error_message: Some(err.to_string()),
        },
    }
}

fn store_result(app: &AppHandle, outcome: &CheckOutcome) -> Result<(), String> {
    let state = app.state::<AppState>();
    let conn = state.db.lock().map_err(|e| e.to_string())?;

    conn.execute(
        "INSERT INTO check_results (target_id, success, status_code, response_time_ms, error_message)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            outcome.target_id,
            outcome.success as i64,
            outcome.status_code,
            outcome.response_time_ms,
            outcome.error_message,
        ],
    )
    .map_err(|e| e.to_string())?;

    conn.execute(
        "UPDATE targets SET last_checked_at = datetime('now') WHERE id = ?1",
        params![outcome.target_id],
    )
    .map_err(|e| e.to_string())?;

    let previous_failures = current_consecutive_failures(&conn, outcome.target_id);
    let new_failures = if outcome.success { 0 } else { previous_failures + 1 };

    conn.execute(
        "INSERT INTO alert_state (target_id, consecutive_failures)
         VALUES (?1, ?2)
         ON CONFLICT(target_id) DO UPDATE SET consecutive_failures = ?2",
        params![outcome.target_id, new_failures],
    )
    .map_err(|e| e.to_string())?;

    drop(conn);

    if !outcome.success && new_failures == FAILURE_ALERT_THRESHOLD {
        notify(
            app,
            &format!("{} đang down", outcome.target_name),
            outcome.error_message.as_deref().unwrap_or("Health check thất bại"),
        );
    } else if outcome.success && previous_failures >= FAILURE_ALERT_THRESHOLD {
        notify(app, &format!("{} đã hoạt động lại", outcome.target_name), "Health check đã thành công");
    }

    Ok(())
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    let state = app.state::<AppState>();
    let enabled = state
        .db
        .lock()
        .map(|conn| settings::notifications_enabled(&conn))
        .unwrap_or(true);
    if !enabled {
        return;
    }
    let _ = app.notification().builder().title(title).body(body).show();
}

fn current_consecutive_failures(conn: &rusqlite::Connection, target_id: i64) -> i64 {
    conn.query_row(
        "SELECT consecutive_failures FROM alert_state WHERE target_id = ?1",
        params![target_id],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

pub fn update_tray_status(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let emoji = compute_tray_emoji(&conn);
    drop(conn);
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_title(Some(emoji));
    }
    Ok(())
}

fn compute_tray_emoji(conn: &rusqlite::Connection) -> &'static str {
    let down_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM targets t WHERE t.enabled = 1 AND EXISTS (
                SELECT 1 FROM check_results cr
                WHERE cr.target_id = t.id AND cr.success = 0
                AND cr.checked_at = (SELECT MAX(checked_at) FROM check_results WHERE target_id = t.id)
             )",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    if down_count > 0 {
        return "🔴";
    }

    let warning_count: i64 = conn
        .query_row(
            "SELECT
                (SELECT COUNT(*) FROM ssl_status WHERE expiry_date IS NOT NULL
                    AND julianday(expiry_date) - julianday('now') <= 14)
              + (SELECT COUNT(*) FROM domain_status WHERE expiry_date IS NOT NULL
                    AND julianday(expiry_date) - julianday('now') <= 30)",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    if warning_count > 0 {
        return "🟡";
    }

    let total: i64 = conn
        .query_row("SELECT COUNT(*) FROM targets WHERE enabled = 1", [], |row| row.get(0))
        .unwrap_or(0);

    if total == 0 {
        "⚪"
    } else {
        "🟢"
    }
}

fn row_to_target(row: &rusqlite::Row) -> rusqlite::Result<Target> {
    Ok(Target {
        id: row.get("id")?,
        name: row.get("name")?,
        url: row.get("url")?,
        group_tag: row.get("group_tag")?,
        check_interval_secs: row.get("check_interval_secs")?,
        enabled: row.get::<_, i64>("enabled")? != 0,
        check_http: row.get::<_, i64>("check_http")? != 0,
        expected_status: row.get("expected_status")?,
        check_ssl: row.get::<_, i64>("check_ssl")? != 0,
        check_domain: row.get::<_, i64>("check_domain")? != 0,
        custom_path: row.get("custom_path")?,
        expected_body_contains: row.get("expected_body_contains")?,
        last_checked_at: row.get("last_checked_at")?,
        created_at: row.get("created_at")?,
    })
}
