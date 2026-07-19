use crate::models::{
    CheckResult, DomainStatus, NewTarget, SslStatus, Target, TargetDetail, TargetOverview, UpdateTarget,
};
use crate::AppState;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use tauri::State;
use tauri_plugin_dialog::DialogExt;

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
        sort_order: row.get("sort_order")?,
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

/// True for a `UNIQUE constraint failed` error from the `idx_targets_url_unique`
/// index (see db.rs) - lets callers turn that specific failure into a friendly
/// "already monitoring this URL" message instead of a raw SQLite error string.
fn is_unique_violation(err: &rusqlite::Error) -> bool {
    matches!(
        err,
        rusqlite::Error::SqliteFailure(e, _) if e.code == rusqlite::ErrorCode::ConstraintViolation
    )
}

const DUPLICATE_URL_ERROR: &str = "A target with this URL already exists";

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
        .prepare("SELECT * FROM targets ORDER BY sort_order ASC, created_at ASC")
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
    let next_sort_order: i64 = conn
        .query_row("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM targets", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO targets (name, url, group_tag, check_interval_secs, check_http,
            expected_status, check_ssl, check_domain, custom_path, expected_body_contains, sort_order)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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
            next_sort_order,
        ],
    )
    .map_err(|e| if is_unique_violation(&e) { DUPLICATE_URL_ERROR.to_string() } else { e.to_string() })?;
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
    .map_err(|e| if is_unique_violation(&e) { DUPLICATE_URL_ERROR.to_string() } else { e.to_string() })?;
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
pub async fn check_target_now(app: tauri::AppHandle, id: i64) -> Result<(), String> {
    crate::scheduler::check_target_now(&app, id).await
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
pub async fn get_target_detail(state: State<'_, AppState>, target_id: i64) -> Result<TargetDetail, String> {
    let (target, ssl_status, domain_status, uptime_24h_pct, uptime_7d_pct, history) = {
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

        (target, ssl_status, domain_status, uptime_24h_pct, uptime_7d_pct, history)
    };

    let resolved_ips = match crate::expiry_check::extract_host(&target.url) {
        Some(host) => crate::expiry_check::resolve_ips(&host).await,
        None => Vec::new(),
    };

    Ok(TargetDetail {
        target,
        ssl_status,
        domain_status,
        uptime_24h_pct,
        uptime_7d_pct,
        history,
        resolved_ips,
    })
}

#[tauri::command]
pub fn get_overview(state: State<AppState>) -> Result<Vec<TargetOverview>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT * FROM targets ORDER BY sort_order ASC, created_at ASC")
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

/// (up_count, enabled_count) among enabled targets, based on each target's
/// most recent check result. Used by both `get_uptime_summary` and the tray
/// menu's periodic refresh.
pub fn uptime_summary(conn: &Connection) -> rusqlite::Result<(i64, i64)> {
    conn.query_row(
        "SELECT
            COALESCE(SUM(CASE WHEN latest.success = 1 THEN 1 ELSE 0 END), 0),
            COUNT(*)
         FROM targets t
         LEFT JOIN (
             SELECT cr.target_id, cr.success
             FROM check_results cr
             JOIN (
                 SELECT target_id, MAX(checked_at) AS max_checked
                 FROM check_results GROUP BY target_id
             ) m ON cr.target_id = m.target_id AND cr.checked_at = m.max_checked
         ) latest ON latest.target_id = t.id
         WHERE t.enabled = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
}

#[tauri::command]
pub fn get_uptime_summary(state: State<AppState>) -> Result<(i64, i64), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    uptime_summary(&conn).map_err(|e| e.to_string())
}

/// Persists a new relative order for a set of targets (e.g. after a
/// drag-and-drop reorder within one group). `ids` must be given in the
/// desired display order; each gets `sort_order` set to its index.
#[tauri::command]
pub fn reorder_targets(state: State<AppState>, ids: Vec<i64>) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    for (index, id) in ids.iter().enumerate() {
        conn.execute(
            "UPDATE targets SET sort_order = ?1 WHERE id = ?2",
            params![index as i64, id],
        )
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Renames a group by re-tagging every target currently in it. Also patches
/// the persisted group display-order (the same JSON list `get_group_order`/
/// `set_group_order` manage) so the renamed group keeps its position instead
/// of falling back to alphabetical placement as an "unknown" name.
#[tauri::command]
pub fn rename_group(state: State<AppState>, old_name: String, new_name: String) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE targets SET group_tag = ?1 WHERE group_tag = ?2",
        params![new_name, old_name],
    )
    .map_err(|e| e.to_string())?;

    let raw: String = conn
        .query_row("SELECT value FROM app_settings WHERE key = 'group_order'", [], |row| row.get(0))
        .unwrap_or_else(|_| "[]".to_string());
    let mut order: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
    for name in order.iter_mut() {
        if *name == old_name {
            *name = new_name.clone();
        }
    }
    let updated = serde_json::to_string(&order).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO app_settings (key, value) VALUES ('group_order', ?1)
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        params![updated],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

// Only the target *settings* travel in an export, not history/ssl/domain
// status or ids/timestamps — those are per-machine derived data that a fresh
// import will re-populate on its own once the scheduler starts checking.
#[derive(Debug, Serialize, Deserialize)]
struct ExportedTarget {
    name: String,
    url: String,
    group_tag: Option<String>,
    check_interval_secs: i64,
    enabled: bool,
    check_http: bool,
    expected_status: i64,
    check_ssl: bool,
    check_domain: bool,
    custom_path: Option<String>,
    expected_body_contains: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct DomainsExportFile {
    format: String,
    version: u32,
    exported_at: String,
    group_order: Vec<String>,
    targets: Vec<ExportedTarget>,
}

const EXPORT_FORMAT: &str = "dkb-monitor-domains";
const EXPORT_VERSION: u32 = 1;

fn get_group_order(conn: &Connection) -> Vec<String> {
    let raw: String = conn
        .query_row("SELECT value FROM app_settings WHERE key = 'group_order'", [], |row| row.get(0))
        .unwrap_or_else(|_| "[]".to_string());
    serde_json::from_str(&raw).unwrap_or_default()
}

/// Opens a native save dialog and writes every target's settings (plus the
/// custom group display order) to a JSON file. Returns `None` if the user
/// cancels the dialog rather than treating that as an error.
#[tauri::command]
pub async fn export_domains(app: tauri::AppHandle, state: State<'_, AppState>) -> Result<Option<String>, String> {
    let (targets, group_order) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT * FROM targets ORDER BY sort_order ASC, created_at ASC")
            .map_err(|e| e.to_string())?;
        let targets = stmt
            .query_map([], row_to_target)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        (targets, get_group_order(&conn))
    };

    let file = DomainsExportFile {
        format: EXPORT_FORMAT.to_string(),
        version: EXPORT_VERSION,
        exported_at: chrono::Utc::now().to_rfc3339(),
        group_order,
        targets: targets
            .into_iter()
            .map(|t| ExportedTarget {
                name: t.name,
                url: t.url,
                group_tag: t.group_tag,
                check_interval_secs: t.check_interval_secs,
                enabled: t.enabled,
                check_http: t.check_http,
                expected_status: t.expected_status,
                check_ssl: t.check_ssl,
                check_domain: t.check_domain,
                custom_path: t.custom_path,
                expected_body_contains: t.expected_body_contains,
            })
            .collect(),
    };
    let json = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;

    let Some(path) = app
        .dialog()
        .file()
        .set_file_name("dkb-monitor-domains.json")
        .add_filter("JSON", &["json"])
        .blocking_save_file()
    else {
        return Ok(None);
    };
    let path = path.into_path().map_err(|e| e.to_string())?;
    std::fs::write(&path, json).map_err(|e| e.to_string())?;
    Ok(Some(path.display().to_string()))
}

#[derive(Debug, Serialize)]
pub struct ImportResult {
    imported: usize,
    skipped: usize,
}

/// Opens a native open-file dialog and appends every target found in the
/// chosen export file to this machine's target list (existing targets are
/// left untouched). Targets whose URL already exists here (case/whitespace
/// insensitive, same rule as the `idx_targets_url_unique` index) are silently
/// skipped rather than failing the whole import, since the common case is
/// re-importing an overlapping list across machines. Returns `None` if the
/// user cancels the dialog.
#[tauri::command]
pub async fn import_domains(app: tauri::AppHandle, state: State<'_, AppState>) -> Result<Option<ImportResult>, String> {
    let Some(path) = app.dialog().file().add_filter("JSON", &["json"]).blocking_pick_file() else {
        return Ok(None);
    };
    let path = path.into_path().map_err(|e| e.to_string())?;
    let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let file: DomainsExportFile =
        serde_json::from_str(&content).map_err(|e| format!("Invalid domains export file: {e}"))?;
    if file.format != EXPORT_FORMAT {
        return Err("This file isn't a DKB Monitor domains export".to_string());
    }

    let mut conn = state.db.lock().map_err(|e| e.to_string())?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    let mut next_sort_order: i64 = tx
        .query_row("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM targets", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;
    let mut imported = 0usize;
    let mut skipped = 0usize;
    for target in file.targets {
        let already_exists: bool = tx
            .query_row(
                "SELECT 1 FROM targets WHERE lower(trim(url)) = lower(trim(?1))",
                params![target.url],
                |_| Ok(()),
            )
            .optional()
            .map_err(|e| e.to_string())?
            .is_some();
        if already_exists {
            skipped += 1;
            continue;
        }
        tx.execute(
            "INSERT INTO targets (name, url, group_tag, check_interval_secs, enabled, check_http,
                expected_status, check_ssl, check_domain, custom_path, expected_body_contains, sort_order)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
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
                next_sort_order,
            ],
        )
        .map_err(|e| e.to_string())?;
        next_sort_order += 1;
        imported += 1;
    }

    // Merge in any imported group names not already in this machine's order
    // so groups keep the exported ordering instead of falling back to
    // alphabetical placement, without discarding groups already here.
    let mut order = get_group_order(&tx);
    for name in &file.group_order {
        if !order.contains(name) {
            order.push(name.clone());
        }
    }
    let updated = serde_json::to_string(&order).map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO app_settings (key, value) VALUES ('group_order', ?1)
         ON CONFLICT(key) DO UPDATE SET value = ?1",
        params![updated],
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;
    Ok(Some(ImportResult { imported, skipped }))
}

/// Deletes every target (check history/ssl/domain status cascade via the FK
/// constraints in db.rs). The frontend is responsible for confirming with the
/// user first - this command performs the deletion unconditionally.
#[tauri::command]
pub fn clear_all_targets(state: State<AppState>) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM targets", []).map_err(|e| e.to_string())?;
    Ok(())
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
