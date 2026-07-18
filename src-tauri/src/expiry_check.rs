use chrono::NaiveDate;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const CHECK_TIMEOUT_SECS: u64 = 10;

pub fn extract_host(url: &str) -> Option<String> {
    reqwest::Url::parse(url).ok()?.host_str().map(|h| h.to_string())
}

/// Best-effort registrable-domain extraction (handles common two-part
/// ccSLDs like .co.uk / .com.vn). Not a full public-suffix-list implementation.
pub fn extract_registrable_domain(host: &str) -> String {
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() <= 2 {
        return host.to_string();
    }
    const CC_SECOND_LEVEL: [&str; 6] = ["co", "com", "net", "org", "gov", "edu"];
    let second_last = parts[parts.len() - 2];
    let last = parts[parts.len() - 1];
    if last.len() == 2 && CC_SECOND_LEVEL.contains(&second_last) {
        parts[parts.len() - 3..].join(".")
    } else {
        parts[parts.len() - 2..].join(".")
    }
}

/// Runs `openssl s_client` (stdin closed, so it exits right after the TLS
/// handshake) piped into `openssl x509 -noout -enddate`. Both processes are
/// invoked with an explicit argument array (never a shell string), so the
/// host — which comes from user-entered target config — cannot break out
/// into shell metacharacters.
pub async fn check_ssl_expiry(host: &str) -> Result<Option<String>, String> {
    let connect_arg = format!("{host}:443");
    let fut = async {
        let s_client = Command::new("openssl")
            .args(["s_client", "-connect", &connect_arg, "-servername", host])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;

        let cert_output = s_client.wait_with_output().await.map_err(|e| e.to_string())?;

        let mut x509 = Command::new("openssl")
            .args(["x509", "-noout", "-enddate"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;

        if let Some(mut stdin) = x509.stdin.take() {
            let _ = stdin.write_all(&cert_output.stdout).await;
        }
        let x509_output = x509.wait_with_output().await.map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&x509_output.stdout);
        Ok(parse_openssl_enddate(&text))
    };

    tokio::time::timeout(Duration::from_secs(CHECK_TIMEOUT_SECS), fut)
        .await
        .unwrap_or(Ok(None))
}

fn parse_openssl_enddate(text: &str) -> Option<String> {
    let raw = text.trim();
    let raw = raw.strip_prefix("notAfter=").unwrap_or(raw);
    if raw.is_empty() {
        return None;
    }
    chrono::NaiveDateTime::parse_from_str(raw, "%b %e %H:%M:%S %Y GMT")
        .ok()
        .map(|dt| dt.date().format("%Y-%m-%d").to_string())
}

/// Runs the system `whois` binary with the domain as a single argument
/// (never shell-interpolated) and best-effort parses common expiry-line
/// formats. Unparseable output yields `None` rather than an error, since
/// WHOIS reply formats vary a lot across registrars/TLDs.
pub async fn check_domain_expiry(domain: &str) -> Result<Option<String>, String> {
    let fut = async {
        let output = Command::new("whois")
            .arg(domain)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .await
            .map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&output.stdout);
        Ok(parse_whois_expiry(&text))
    };

    tokio::time::timeout(Duration::from_secs(CHECK_TIMEOUT_SECS), fut)
        .await
        .unwrap_or(Ok(None))
}

const EXPIRY_LINE_PATTERNS: [&str; 6] = [
    "registry expiry date:",
    "registrar registration expiration date:",
    "expiration date:",
    "expiry date:",
    "paid-till:",
    "expire date:",
];

fn parse_whois_expiry(text: &str) -> Option<String> {
    for line in text.lines() {
        let lower = line.to_lowercase();
        for pattern in EXPIRY_LINE_PATTERNS {
            if let Some(idx) = lower.find(pattern) {
                let value = line[idx + pattern.len()..].trim();
                if let Some(date) = normalize_whois_date(value) {
                    return Some(date);
                }
            }
        }
    }
    None
}

fn normalize_whois_date(raw: &str) -> Option<String> {
    let cleaned = raw.split(['T', ' ']).next().unwrap_or(raw);
    NaiveDate::parse_from_str(cleaned, "%Y-%m-%d")
        .ok()
        .map(|d| d.format("%Y-%m-%d").to_string())
}
