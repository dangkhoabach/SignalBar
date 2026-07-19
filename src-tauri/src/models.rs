use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Target {
    pub id: i64,
    pub name: String,
    pub url: String,
    pub group_tag: Option<String>,
    pub check_interval_secs: i64,
    pub enabled: bool,
    pub check_http: bool,
    pub expected_status: i64,
    pub check_ssl: bool,
    pub check_domain: bool,
    pub custom_path: Option<String>,
    pub expected_body_contains: Option<String>,
    pub last_checked_at: Option<String>,
    pub paused_until: Option<String>,
    pub sort_order: i64,
    pub created_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct NewTarget {
    pub name: String,
    pub url: String,
    pub group_tag: Option<String>,
    pub check_interval_secs: i64,
    pub check_http: bool,
    pub expected_status: i64,
    pub check_ssl: bool,
    pub check_domain: bool,
    pub custom_path: Option<String>,
    pub expected_body_contains: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct UpdateTarget {
    pub id: i64,
    pub name: String,
    pub url: String,
    pub group_tag: Option<String>,
    pub check_interval_secs: i64,
    pub enabled: bool,
    pub check_http: bool,
    pub expected_status: i64,
    pub check_ssl: bool,
    pub check_domain: bool,
    pub custom_path: Option<String>,
    pub expected_body_contains: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CheckResult {
    pub id: i64,
    pub target_id: i64,
    pub checked_at: String,
    pub success: bool,
    pub status_code: Option<i64>,
    pub response_time_ms: Option<i64>,
    pub error_message: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct SslStatus {
    pub target_id: i64,
    pub expiry_date: Option<String>,
    pub last_checked: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct DomainStatus {
    pub target_id: i64,
    pub expiry_date: Option<String>,
    pub last_checked: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TargetOverview {
    pub target: Target,
    pub latest_check: Option<CheckResult>,
    pub ssl_status: Option<SslStatus>,
    pub domain_status: Option<DomainStatus>,
    pub uptime_24h_pct: Option<f64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TargetDetail {
    pub target: Target,
    pub ssl_status: Option<SslStatus>,
    pub domain_status: Option<DomainStatus>,
    pub uptime_24h_pct: Option<f64>,
    pub uptime_7d_pct: Option<f64>,
    pub history: Vec<CheckResult>,
    pub resolved_ips: Vec<String>,
    pub incidents: Vec<Incident>,
}

/// A run of consecutive failed checks, derived from `check_results` rather
/// than stored directly. `ended_at` is `None` while the incident is still
/// ongoing (the most recent check in the run is still a failure).
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Incident {
    pub started_at: String,
    pub ended_at: Option<String>,
    pub error_message: Option<String>,
}
