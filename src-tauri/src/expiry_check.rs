use chrono::NaiveDate;
use std::collections::HashMap;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::sync::OnceCell;

const CHECK_TIMEOUT_SECS: u64 = 10;
const DOMAIN_CHECK_TIMEOUT_SECS: u64 = 20;

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

/// Resolves the host's current A/AAAA records via the OS resolver. Run live
/// on each detail-page load rather than cached/scheduled, since it's cheap
/// and the point is to reflect the DNS state right now (e.g. right after a
/// user repoints a domain).
pub async fn resolve_ips(host: &str) -> Vec<String> {
    let fut = tokio::net::lookup_host((host, 0));
    let addrs = match tokio::time::timeout(Duration::from_secs(5), fut).await {
        Ok(Ok(iter)) => iter.map(|a| a.ip().to_string()).collect::<Vec<_>>(),
        _ => return Vec::new(),
    };
    let mut ips: Vec<String> = addrs.into_iter().collect();
    ips.sort();
    ips.dedup();
    ips
}

/// Prefers RDAP (a JSON-over-HTTPS protocol) over the legacy `whois`
/// command: `whois` on macOS chains two full network round-trips (root
/// registry, then the registrar it refers to) with no read timeout of its
/// own, so a slow or unresponsive referral target hangs the whole check.
/// RDAP is a single HTTPS request, so it's both faster and immune to that
/// class of hang. Not every TLD has an RDAP server (notably .vn does not),
/// so `whois` remains as a fallback for those.
pub async fn check_domain_expiry(domain: &str) -> Result<Option<String>, String> {
    let fut = async {
        if let Some(date) = rdap_domain_expiry(domain).await {
            return Ok(Some(date));
        }
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

    tokio::time::timeout(Duration::from_secs(DOMAIN_CHECK_TIMEOUT_SECS), fut)
        .await
        .unwrap_or(Ok(None))
}

/// TLD -> RDAP base URL, per IANA's bootstrap registry. Fetched once and
/// cached for the process lifetime (the mapping essentially never changes
/// at runtime).
static RDAP_BOOTSTRAP: OnceCell<HashMap<String, String>> = OnceCell::const_new();

async fn rdap_bootstrap() -> &'static HashMap<String, String> {
    RDAP_BOOTSTRAP
        .get_or_init(|| async { fetch_rdap_bootstrap().await.unwrap_or_default() })
        .await
}

async fn fetch_rdap_bootstrap() -> Option<HashMap<String, String>> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .ok()?;
    let json: serde_json::Value = client
        .get("https://data.iana.org/rdap/dns.json")
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    let mut map = HashMap::new();
    for entry in json.get("services")?.as_array()? {
        let arr = entry.as_array()?;
        let tlds = arr.first()?.as_array()?;
        let url = arr.get(1)?.as_array()?.first()?.as_str()?.to_string();
        for tld in tlds {
            if let Some(t) = tld.as_str() {
                map.insert(t.to_lowercase(), url.clone());
            }
        }
    }
    Some(map)
}

#[derive(serde::Deserialize)]
struct RdapEvent {
    #[serde(rename = "eventAction")]
    event_action: String,
    #[serde(rename = "eventDate")]
    event_date: String,
}

#[derive(serde::Deserialize)]
struct RdapDomain {
    events: Option<Vec<RdapEvent>>,
}

async fn rdap_domain_expiry(domain: &str) -> Option<String> {
    let tld = domain.rsplit('.').next()?.to_lowercase();
    let base = rdap_bootstrap().await.get(&tld)?;
    let base = base.trim_end_matches('/');

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .ok()?;
    let resp: RdapDomain = client
        .get(format!("{base}/domain/{domain}"))
        .header("Accept", "application/rdap+json")
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;

    let raw = resp
        .events?
        .into_iter()
        .find(|e| e.event_action == "expiration")?
        .event_date;
    chrono::DateTime::parse_from_rfc3339(&raw)
        .ok()
        .map(|dt| dt.format("%Y-%m-%d").to_string())
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
