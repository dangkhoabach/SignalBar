export type SmtpFrequency = "daily" | "weekly" | "monthly";

export interface AppSettings {
  notifications_enabled: boolean;
  smtp_enabled: boolean;
  smtp_recipient_email: string;
  smtp_frequency: SmtpFrequency;
  /// 0 = Monday .. 6 = Sunday (chrono's num_days_from_monday convention)
  smtp_day_of_week: number;
  smtp_day_of_month: number;
  /** Consecutive HTTP failures before a "target is down" alert fires. */
  failure_alert_threshold: number;
  /** Response time (ms) that must be exceeded for failure_alert_threshold consecutive checks before a "slow" alert fires. 0 disables it. */
  response_time_alert_threshold_ms: number;
  ssl_alert_threshold_days: number;
  domain_alert_threshold_days: number;
  /** How long check history is kept before being pruned; 0 = keep forever. */
  history_retention_days: number;
  /** CPU/SoC temperature (°C) that triggers a "running hot" alert. 0 disables it. */
  system_temp_alert_threshold_celsius: number;
  /** Battery percentage (while unplugged) that triggers a "battery low" alert. 0 disables it. */
  battery_low_alert_threshold_percent: number;
}

export type UpdateSettingsInput = AppSettings;
