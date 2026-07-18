use crate::settings::AppSettings;
use lettre::message::header::ContentType;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{Message, SmtpTransport, Transport};
use rusqlite::params;

/// Sends a plain-text email via STARTTLS using credentials the caller
/// retrieved from the OS keychain. Runs the (blocking) lettre transport on
/// a dedicated thread so it doesn't stall the async runtime.
pub async fn send_email(settings: &AppSettings, password: &str, subject: &str, body: &str) -> Result<(), String> {
    let settings = settings.clone();
    let password = password.to_string();
    let subject = subject.to_string();
    let body = body.to_string();

    tokio::task::spawn_blocking(move || -> Result<(), String> {
        let email = Message::builder()
            .from(settings.smtp_sender_email.parse().map_err(|e: lettre::address::AddressError| e.to_string())?)
            .to(settings
                .smtp_recipient_email
                .parse()
                .map_err(|e: lettre::address::AddressError| e.to_string())?)
            .subject(subject)
            .header(ContentType::TEXT_PLAIN)
            .body(body)
            .map_err(|e| e.to_string())?;

        let creds = Credentials::new(settings.smtp_sender_email.clone(), password);

        let transport = SmtpTransport::starttls_relay(&settings.smtp_host)
            .map_err(|e| e.to_string())?
            .port(settings.smtp_port as u16)
            .credentials(creds)
            .build();

        transport.send(&email).map_err(|e| e.to_string())?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
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
