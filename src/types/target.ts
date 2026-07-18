export interface Target {
  id: number;
  name: string;
  url: string;
  group_tag: string | null;
  check_interval_secs: number;
  enabled: boolean;
  check_http: boolean;
  expected_status: number;
  check_ssl: boolean;
  check_domain: boolean;
  custom_path: string | null;
  expected_body_contains: string | null;
  created_at: string;
}

export interface NewTarget {
  name: string;
  url: string;
  group_tag: string | null;
  check_interval_secs: number;
  check_http: boolean;
  expected_status: number;
  check_ssl: boolean;
  check_domain: boolean;
  custom_path: string | null;
  expected_body_contains: string | null;
}

export interface UpdateTarget extends NewTarget {
  id: number;
  enabled: boolean;
}

export interface CheckResult {
  id: number;
  target_id: number;
  checked_at: string;
  success: boolean;
  status_code: number | null;
  response_time_ms: number | null;
  error_message: string | null;
}

export interface SslStatus {
  target_id: number;
  expiry_date: string | null;
  last_checked: string;
}

export interface DomainStatus {
  target_id: number;
  expiry_date: string | null;
  last_checked: string;
}

export interface TargetOverview {
  target: Target;
  latest_check: CheckResult | null;
  ssl_status: SslStatus | null;
  domain_status: DomainStatus | null;
  uptime_24h_pct: number | null;
}

export interface TargetDetail {
  target: Target;
  ssl_status: SslStatus | null;
  domain_status: DomainStatus | null;
  uptime_24h_pct: number | null;
  uptime_7d_pct: number | null;
  history: CheckResult[];
}
