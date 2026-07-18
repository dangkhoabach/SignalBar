use crate::models::{
    CheckResult, DomainStatus, NewTarget, SslStatus, Target, TargetDetail, TargetOverview, UpdateTarget,
};
use crate::AppState;
use rusqlite::{params, Connection, OptionalExtension};
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

fn get_ssl_status(conn: &Connection, target_id: i64) -> rusqlite::Result<Option<SslStatus>> {
    conn.query_row(
        "SELECT * FROM ssl_status WHERE target_id = ?1",
        params![target_id],
        |row| {
            Ok(SslStatus {
                target_id: row.get("target_id")?,
                expiry_date: row.get("expiry_date")?,
                last_checked: row.get("last_checked")?,
            })
        },
    )
    .optional()
}

fn get_domain_status(conn: &Connection, target_id: i64) -> rusqlite::Result<Option<DomainStatus>> {
    conn.query_row(
        "SELECT * FROM domain_status WHERE target_id = ?1",
        params![target_id],
        |row| {
            Ok(DomainStatus {
                target_id: row.get("target_id")?,
                expiry_date: row.get("expiry_date")?,
                last_checked: row.get("last_checked")?,
            })
        },
    )
    .optional()
}

fn get_uptime_pct(conn: &Connection, target_id: i64, since_modifier: &str) -> rusqlite::Result<Option<f64>> {
    conn.query_row(
        &format!(
            "SELECT AVG(success) * 100.0 FROM check_results
             WHERE target_id = ?1 AND checked_at >= datetime('now', '{since_modifier}')"
        ),
        params![target_id],
        |row| row.get(0),
    )
}

/// Uses the caller's explicit group if given; otherwise groups the target
/// under its registrable root domain (e.g. `tools.example.com` and
/// `example.com` both land in the "example.com" group) so related
/// subdomains organize themselves without the user typing anything.
fn resolve_group_tag(group_tag: Option<String>, url: &str) -> Option<String> {
    if let Some(tag) = group_tag {
        if !tag.trim().is_empty() {
            return Some(tag);
        }
    }
    let host = crate::expiry_check::extract_host(url)?;
    Some(crate::expiry_check::extract_registrable_domain(&host))
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
    let group_tag = resolve_group_tag(target.group_tag, &target.url);
    conn.execute(
        "INSERT INTO targets (name, url, group_tag, check_interval_secs, check_http,
            expected_status, check_ssl, check_domain, custom_path, expected_body_contains)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            target.name,
            target.url,
            group_tag,
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
    let group_tag = resolve_group_tag(target.group_tag, &target.url);
    conn.execute(
        "UPDATE targets SET name = ?1, url = ?2, group_tag = ?3, check_interval_secs = ?4,
            enabled = ?5, check_http = ?6, expected_status = ?7, check_ssl = ?8,
            check_domain = ?9, custom_path = ?10, expected_body_contains = ?11
         WHERE id = ?12",
        params![
            target.name,
            target.url,
            group_tag,
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
pub fn get_target_detail(state: State<AppState>, target_id: i64) -> Result<TargetDetail, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;

    let target = conn
        .query_row("SELECT * FROM targets WHERE id = ?1", params![target_id], row_to_target)
        .map_err(|e| e.to_string())?;

    let ssl_status = get_ssl_status(&conn, target_id).map_err(|e| e.to_string())?;
    let domain_status = get_domain_status(&conn, target_id).map_err(|e| e.to_string())?;
    let uptime_24h_pct = get_uptime_pct(&conn, target_id, "-1 day").map_err(|e| e.to_string())?;
    let uptime_7d_pct = get_uptime_pct(&conn, target_id, "-7 day").map_err(|e| e.to_string())?;

    let mut stmt = conn
        .prepare("SELECT * FROM check_results WHERE target_id = ?1 ORDER BY checked_at DESC LIMIT 100")
        .map_err(|e| e.to_string())?;
    let history = stmt
        .query_map(params![target_id], row_to_check_result)
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    Ok(TargetDetail {
        target,
        ssl_status,
        domain_status,
        uptime_24h_pct,
        uptime_7d_pct,
        history,
    })
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

        let ssl_status = get_ssl_status(&conn, target.id).map_err(|e| e.to_string())?;
        let domain_status = get_domain_status(&conn, target.id).map_err(|e| e.to_string())?;
        let uptime_24h_pct = get_uptime_pct(&conn, target.id, "-1 day").map_err(|e| e.to_string())?;

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

#[cfg(test)]
mod resolve_group_tag_tests {
    use super::resolve_group_tag;

    #[test]
    fn groups_subdomains_under_root_domain() {
        assert_eq!(
            resolve_group_tag(None, "https://dangkhoabach.vn"),
            Some("dangkhoabach.vn".to_string())
        );
        assert_eq!(
            resolve_group_tag(None, "https://tools.dangkhoabach.vn"),
            Some("dangkhoabach.vn".to_string())
        );
        assert_eq!(
            resolve_group_tag(None, "https://admin.dangkhoabach.vn"),
            Some("dangkhoabach.vn".to_string())
        );
        assert_eq!(
            resolve_group_tag(Some("Custom".to_string()), "https://tools.dangkhoabach.vn"),
            Some("Custom".to_string())
        );
        assert_eq!(
            resolve_group_tag(Some("".to_string()), "https://tools.dangkhoabach.vn"),
            Some("dangkhoabach.vn".to_string())
        );
    }
}
