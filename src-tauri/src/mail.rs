use rusqlite::params;
use serde::{Deserialize, Serialize};

const RELAY_ENDPOINT: &str = "https://admin.dangkhoabach.vn/api/dkb-monitor/notify";

#[derive(Serialize)]
struct RelayRequest<'a> {
    #[serde(rename = "recipientEmail")]
    recipient_email: &'a str,
    subject: &'a str,
    body: &'a str,
}

#[derive(Deserialize)]
struct RelayResponse {
    sent: bool,
}

/// Sends through this app's own backend rather than any user-supplied SMTP
/// account. The server wraps `body` in its own HTML template and relays it
/// through an SMTP account it already controls, so no email credential of
/// any kind is ever stored in or shipped with this app.
pub async fn send_email_via_relay(client: &reqwest::Client, recipient: &str, subject: &str, body: &str) -> Result<(), String> {
    let response = client
        .post(RELAY_ENDPOINT)
        .json(&RelayRequest { recipient_email: recipient, subject, body })
        .send()
        .await
        .map_err(|e| e.to_string())?;

    if !response.status().is_success() {
        return Err(format!("relay responded with {}", response.status()));
    }

    let parsed: RelayResponse = response.json().await.map_err(|e| e.to_string())?;
    if !parsed.sent {
        return Err("relay could not deliver the email".to_string());
    }
    Ok(())
}

pub fn generate_report(conn: &rusqlite::Connection, label: &str, days: i64) -> Result<String, String> {
    let mut stmt = conn
        .prepare("SELECT id, name FROM targets ORDER BY name ASC")
        .map_err(|e| e.to_string())?;
    let targets: Vec<(i64, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    if targets.is_empty() {
        return Ok(format!("DKB Monitor — {label} Report\n\nNo targets configured."));
    }

    let window = format!("-{days} day");
    let mut lines = vec![format!("DKB Monitor — {label} Report (last {days} days)"), String::new()];

    for (id, name) in targets {
        let uptime: Option<f64> = conn
            .query_row(
                "SELECT AVG(success) * 100.0 FROM check_results
                 WHERE target_id = ?1 AND checked_at >= datetime('now', ?2)",
                params![id, window],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;

        let down_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM check_results
                 WHERE target_id = ?1 AND success = 0 AND checked_at >= datetime('now', ?2)",
                params![id, window],
                |row| row.get(0),
            )
            .unwrap_or(0);

        let ssl_expiry: Option<String> = conn
            .query_row("SELECT expiry_date FROM ssl_status WHERE target_id = ?1", params![id], |row| row.get(0))
            .ok()
            .flatten();

        let domain_expiry: Option<String> = conn
            .query_row("SELECT expiry_date FROM domain_status WHERE target_id = ?1", params![id], |row| row.get(0))
            .ok()
            .flatten();

        let uptime_str = uptime.map(|u| format!("{u:.1}%")).unwrap_or_else(|| "n/a".to_string());
        let mut line = format!("- {name}: {uptime_str} uptime, {down_count} failed checks");
        if let Some(d) = ssl_expiry {
            line.push_str(&format!(", SSL expires {d}"));
        }
        if let Some(d) = domain_expiry {
            line.push_str(&format!(", domain expires {d}"));
        }
        lines.push(line);
    }

    Ok(lines.join("\n"))
}
