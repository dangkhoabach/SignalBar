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
                 AND (paused_until IS NULL OR paused_until <= datetime('now'))
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

    maybe_send_report(app).await;
    maybe_cleanup_history(app);
    check_system_alerts(app);

    Ok(())
}

/// Fires once when a reading first crosses its threshold, then stays silent
/// until it drops back below — the same "alert on transition, not on every
/// tick while still bad" shape as the target down/up alerts above, just with
/// a single app-wide flag (in `app_settings`) instead of a per-target row,
/// since there's only one machine to watch here.
fn check_system_alerts(app: &AppHandle) {
    let settings = {
        let state = app.state::<AppState>();
        let Ok(conn) = state.db.lock() else { return };
        settings::load_settings(&conn)
    };

    if settings.system_temp_alert_threshold_celsius <= 0 && settings.battery_low_alert_threshold_percent <= 0 {
        return;
    }

    let stats = {
        let sys_state = app.state::<crate::sysstats::SysState>();
        let Ok(mut inner) = sys_state.inner.lock() else { return };
        crate::sysstats::snapshot(&mut inner)
    };

    if settings.system_temp_alert_threshold_celsius > 0 {
        if let Some(temp) = stats.cpu_temp_celsius {
            let is_hot = temp >= settings.system_temp_alert_threshold_celsius as f32;
            let was_active = alert_flag(app, "system_temp_alert_active");
            if is_hot && !was_active {
                notify(
                    app,
                    "Nhiệt độ máy đang cao",
                    &format!("{temp:.0}°C (ngưỡng {}°C)", settings.system_temp_alert_threshold_celsius),
                );
                set_alert_flag(app, "system_temp_alert_active", true);
            } else if !is_hot && was_active {
                set_alert_flag(app, "system_temp_alert_active", false);
            }
        }
    }

    if settings.battery_low_alert_threshold_percent > 0 {
        if let Some(percent) = stats.battery_percent {
            let charging = stats.battery_charging.unwrap_or(false);
            let is_low = !charging && percent <= settings.battery_low_alert_threshold_percent as f32;
            let was_active = alert_flag(app, "system_battery_alert_active");
            if is_low && !was_active {
                notify(app, "Pin yếu", &format!("Còn {percent:.0}% — hãy cắm sạc"));
                set_alert_flag(app, "system_battery_alert_active", true);
            } else if (!is_low || charging) && was_active {
                set_alert_flag(app, "system_battery_alert_active", false);
            }
        }
    }
}

fn alert_flag(app: &AppHandle, key: &str) -> bool {
    let state = app.state::<AppState>();
    let Ok(conn) = state.db.lock() else { return false };
    conn.query_row("SELECT value FROM app_settings WHERE key = ?1", params![key], |row| row.get::<_, String>(0))
        .optional()
        .ok()
        .flatten()
        .as_deref()
        == Some("1")
}

fn set_alert_flag(app: &AppHandle, key: &str, active: bool) {
    let state = app.state::<AppState>();
    let Ok(conn) = state.db.lock() else { return };
    let _ = conn.execute(
        "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = ?2",
        params![key, if active { "1" } else { "0" }],
    );
}

/// check_results accumulates a row per target per check_interval forever
/// otherwise; for a 24/7 background monitor that adds up over months. Runs
/// at most once a day, guarded the same way as the report scheduler (a
/// stored date string compared against today).
fn maybe_cleanup_history(app: &AppHandle) {
    let state = app.state::<AppState>();
    let Ok(conn) = state.db.lock() else { return };

    let retention_days = settings::load_settings(&conn).history_retention_days;
    if retention_days <= 0 {
        return;
    }

    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let last_cleanup = conn
        .query_row(
            "SELECT value FROM app_settings WHERE key = 'last_history_cleanup_date'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap_or_default();
    if last_cleanup == today {
        return;
    }

    let window = format!("-{retention_days} day");
    let _ = conn.execute(
        "DELETE FROM check_results WHERE checked_at < datetime('now', ?1)",
        params![window],
    );
    let _ = conn.execute(
        "INSERT INTO app_settings (key, value) VALUES ('last_history_cleanup_date', ?1)
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        params![today],
    );
}

/// The scheduler ticks every 15s all day, so "due" needs both a trigger
/// condition (today matches the configured day) and a dedupe guard (already
/// sent for this period) — otherwise it would fire on every tick for the
/// rest of the matching day. The guard value's format doubles as the period
/// identifier (a date, an ISO week, or a year-month), so switching frequency
/// naturally invalidates any stale guard from a different cadence instead of
/// needing separate keys per frequency.
fn report_period(today: chrono::DateTime<chrono::Utc>, frequency: &str, day_of_week: i64, day_of_month: i64) -> Option<(bool, String, &'static str, i64)> {
    use chrono::Datelike;
    match frequency {
        "daily" => Some((true, today.format("%Y-%m-%d").to_string(), "Daily", 1)),
        "weekly" => {
            let due = today.weekday().num_days_from_monday() as i64 == day_of_week;
            Some((due, today.format("%G-W%V").to_string(), "Weekly", 7))
        }
        _ => {
            let due = today.day() as i64 == day_of_month;
            Some((due, today.format("%Y-%m").to_string(), "Monthly", 30))
        }
    }
}

async fn maybe_send_report(app: &AppHandle) {
    let (should_send, report_settings, label, days) = {
        let state = app.state::<AppState>();
        let Ok(conn) = state.db.lock() else { return };
        let s = settings::load_settings(&conn);

        if !s.smtp_enabled || !s.has_smtp_password {
            return;
        }

        let today = chrono::Utc::now();
        let Some((trigger_matches, current_period, label, days)) =
            report_period(today, &s.smtp_frequency, s.smtp_day_of_week, s.smtp_day_of_month)
        else {
            return;
        };

        let last_sent = conn
            .query_row(
                "SELECT value FROM app_settings WHERE key = 'last_report_sent_period'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap_or_default();

        let due = trigger_matches && last_sent != current_period;
        (due, s, label, days)
    };

    if !should_send {
        return;
    }

    let state = app.state::<AppState>();
    let (body, password) = {
        let Ok(conn) = state.db.lock() else { return };
        let body = match mail::generate_report(&conn, label, days) {
            Ok(b) => b,
            Err(err) => {
                eprintln!("report generation error: {err}");
                return;
            }
        };
        let Some(password) = settings::smtp_password(&conn) else { return };
        (body, password)
    };

    match mail::send_email(&report_settings, &password, &format!("DKB Monitor — {label} Report"), &body).await {
        Ok(()) => {
            if let Ok(conn) = state.db.lock() {
                let today = chrono::Utc::now();
                if let Some((_, current_period, _, _)) =
                    report_period(today, &report_settings.smtp_frequency, report_settings.smtp_day_of_week, report_settings.smtp_day_of_month)
                {
                    let _ = conn.execute(
                        "INSERT INTO app_settings (key, value) VALUES ('last_report_sent_period', ?1)
                         ON CONFLICT(key) DO UPDATE SET value = ?1",
                        params![current_period],
                    );
                }
            }
        }
        Err(err) => eprintln!("report send error: {err}"),
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
                 AND (t.paused_until IS NULL OR t.paused_until <= datetime('now'))
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
                 AND (t.paused_until IS NULL OR t.paused_until <= datetime('now'))
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

    let threshold_days = settings::load_settings(&conn).ssl_alert_threshold_days;
    let days_remaining = days_until(&expiry_date);
    let should_alert = days_remaining
        .map(|d| d <= threshold_days && !alerted_today(&previous_alert))
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

    let threshold_days = settings::load_settings(&conn).domain_alert_threshold_days;
    let days_remaining = days_until(&expiry_date);
    let should_alert = days_remaining
        .map(|d| d <= threshold_days && !alerted_today(&previous_alert))
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

    let app_settings = settings::load_settings(&conn);
    let failure_threshold = app_settings.failure_alert_threshold;

    // Only a successful-but-slow response counts toward this streak — an
    // outright failure is already covered by the down alert above, and
    // mixing the two would make both dedupe counters unreliable.
    let previous_slow = current_consecutive_slow(&conn, outcome.target_id);
    let is_slow = app_settings.response_time_alert_threshold_ms > 0
        && outcome.success
        && outcome.response_time_ms > app_settings.response_time_alert_threshold_ms;
    let new_slow = if is_slow { previous_slow + 1 } else { 0 };

    conn.execute(
        "INSERT INTO alert_state (target_id, consecutive_failures, consecutive_slow)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(target_id) DO UPDATE SET consecutive_failures = ?2, consecutive_slow = ?3",
        params![outcome.target_id, new_failures, new_slow],
    )
    .map_err(|e| e.to_string())?;

    drop(conn);

    if !outcome.success && new_failures == failure_threshold {
        notify(
            app,
            &format!("{} đang down", outcome.target_name),
            outcome.error_message.as_deref().unwrap_or("Health check thất bại"),
        );
    } else if outcome.success && previous_failures >= failure_threshold {
        notify(app, &format!("{} đã hoạt động lại", outcome.target_name), "Health check đã thành công");
    } else if new_slow == failure_threshold {
        notify(
            app,
            &format!("{} phản hồi chậm", outcome.target_name),
            &format!(
                "{}ms (ngưỡng {}ms)",
                outcome.response_time_ms, app_settings.response_time_alert_threshold_ms
            ),
        );
    } else if !is_slow && previous_slow >= failure_threshold {
        notify(app, &format!("{} đã phản hồi bình thường trở lại", outcome.target_name), "Response time đã ổn định");
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

fn current_consecutive_slow(conn: &rusqlite::Connection, target_id: i64) -> i64 {
    conn.query_row(
        "SELECT consecutive_slow FROM alert_state WHERE target_id = ?1",
        params![target_id],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

/// On-demand single-target check triggered from the UI ("Check now" in the
/// row menu), bypassing the due-time filters `tick()` uses. Reuses the exact
/// same check/store functions the scheduler runs on its own interval, so
/// results, alert de-dupe, and notifications behave identically either way.
pub async fn check_target_now(app: &AppHandle, target_id: i64) -> Result<(), String> {
    let target = {
        let state = app.state::<AppState>();
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        conn.query_row("SELECT * FROM targets WHERE id = ?1", params![target_id], row_to_target)
            .map_err(|e| e.to_string())?
    };

    if target.check_http {
        let client = app.state::<AppState>().http_client.clone();
        let outcome = run_check(&client, target.clone()).await;
        store_result(app, &outcome)?;
    }

    if target.check_ssl {
        if let Some(host) = expiry_check::extract_host(&target.url) {
            let expiry = expiry_check::check_ssl_expiry(&host).await.unwrap_or(None);
            store_ssl_status(app, &target, expiry)?;
        }
    }

    if target.check_domain {
        if let Some(host) = expiry_check::extract_host(&target.url) {
            let domain = expiry_check::extract_registrable_domain(&host);
            let expiry = expiry_check::check_domain_expiry(&domain).await.unwrap_or(None);
            store_domain_status(app, &target, expiry)?;
        }
    }

    let _ = app.emit("overview-updated", ());
    Ok(())
}

/// Runs `check_target_now` for every enabled target, sequentially, reusing
/// its existing per-target logic and event emission rather than duplicating
/// it. Triggered from the "Check all now" button in the toolbar.
pub async fn check_all_now(app: &AppHandle) -> Result<(), String> {
    let ids: Vec<i64> = {
        let state = app.state::<AppState>();
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                "SELECT id FROM targets
                 WHERE enabled = 1 AND (paused_until IS NULL OR paused_until <= datetime('now'))",
            )
            .map_err(|e| e.to_string())?;
        let ids = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        ids
    };
    for id in ids {
        let _ = check_target_now(app, id).await;
    }
    Ok(())
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
        paused_until: row.get("paused_until")?,
        sort_order: row.get("sort_order")?,
        created_at: row.get("created_at")?,
    })
}
