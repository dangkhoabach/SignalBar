use crate::models::{CheckResult, DomainStatus, NewTarget, SslStatus, Target, TargetOverview, UpdateTarget};
use crate::AppState;
use rusqlite::{params, OptionalExtension};
use tauri::State;

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

fn row_to_check_result(row: &rusqlite::Row) -> rusqlite::Result<CheckResult> {
    Ok(CheckResult {
        id: row.get("id")?,
        target_id: row.get("target_id")?,
        checked_at: row.get("checked_at")?,
        success: row.get::<_, i64>("success")? != 0,
        status_code: row.get("status_code")?,
        response_time_ms: row.get("response_time_ms")?,
        error_message: row.get("error_message")?,
    })
}

#[tauri::command]
pub fn list_targets(state: State<AppState>) -> Result<Vec<Target>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT * FROM targets ORDER BY created_at ASC")
        .map_err(|e| e.to_string())?;
    let targets = stmt
        .query_map([], row_to_target)
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(targets)
}

#[tauri::command]
pub fn add_target(state: State<AppState>, target: NewTarget) -> Result<Target, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO targets (name, url, group_tag, check_interval_secs, check_http,
            expected_status, check_ssl, check_domain, custom_path, expected_body_contains)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            target.name,
            target.url,
            target.group_tag,
            target.check_interval_secs,
            target.check_http as i64,
            target.expected_status,
            target.check_ssl as i64,
            target.check_domain as i64,
            target.custom_path,
            target.expected_body_contains,
        ],
    )
    .map_err(|e| e.to_string())?;
    let id = conn.last_insert_rowid();
    conn.query_row("SELECT * FROM targets WHERE id = ?1", params![id], row_to_target)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn update_target(state: State<AppState>, target: UpdateTarget) -> Result<Target, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE targets SET name = ?1, url = ?2, group_tag = ?3, check_interval_secs = ?4,
            enabled = ?5, check_http = ?6, expected_status = ?7, check_ssl = ?8,
            check_domain = ?9, custom_path = ?10, expected_body_contains = ?11
         WHERE id = ?12",
        params![
            target.name,
            target.url,
            target.group_tag,
            target.check_interval_secs,
            target.enabled as i64,
            target.check_http as i64,
            target.expected_status,
            target.check_ssl as i64,
            target.check_domain as i64,
            target.custom_path,
            target.expected_body_contains,
            target.id,
        ],
    )
    .map_err(|e| e.to_string())?;
    conn.query_row("SELECT * FROM targets WHERE id = ?1", params![target.id], row_to_target)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn delete_target(state: State<AppState>, id: i64) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM targets WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn get_history(state: State<AppState>, target_id: i64, limit: i64) -> Result<Vec<CheckResult>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT * FROM check_results WHERE target_id = ?1
             ORDER BY checked_at DESC LIMIT ?2",
        )
        .map_err(|e| e.to_string())?;
    let results = stmt
        .query_map(params![target_id, limit], row_to_check_result)
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(results)
}

#[tauri::command]
pub fn get_overview(state: State<AppState>) -> Result<Vec<TargetOverview>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT * FROM targets ORDER BY created_at ASC")
        .map_err(|e| e.to_string())?;
    let targets = stmt
        .query_map([], row_to_target)
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let mut overviews = Vec::with_capacity(targets.len());
    for target in targets {
        let latest_check = conn
            .query_row(
                "SELECT * FROM check_results WHERE target_id = ?1 ORDER BY checked_at DESC LIMIT 1",
                params![target.id],
                row_to_check_result,
            )
            .optional()
            .map_err(|e| e.to_string())?;

        let ssl_status = conn
            .query_row(
                "SELECT * FROM ssl_status WHERE target_id = ?1",
                params![target.id],
                |row| {
                    Ok(SslStatus {
                        target_id: row.get("target_id")?,
                        expiry_date: row.get("expiry_date")?,
                        last_checked: row.get("last_checked")?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())?;

        let domain_status = conn
            .query_row(
                "SELECT * FROM domain_status WHERE target_id = ?1",
                params![target.id],
                |row| {
                    Ok(DomainStatus {
                        target_id: row.get("target_id")?,
                        expiry_date: row.get("expiry_date")?,
                        last_checked: row.get("last_checked")?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())?;

        let uptime_24h_pct: Option<f64> = conn
            .query_row(
                "SELECT AVG(success) * 100.0 FROM check_results
                 WHERE target_id = ?1 AND checked_at >= datetime('now', '-1 day')",
                params![target.id],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;

        overviews.push(TargetOverview {
            target,
            latest_check,
            ssl_status,
            domain_status,
            uptime_24h_pct,
        });
    }

    Ok(overviews)
}
