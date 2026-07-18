export type SmtpFrequency = "daily" | "weekly" | "monthly";

export interface AppSettings {
  notifications_enabled: boolean;
  smtp_enabled: boolean;
  smtp_host: string;
  smtp_port: number;
  smtp_sender_email: string;
  smtp_recipient_email: string;
  smtp_frequency: SmtpFrequency;
  /// 0 = Monday .. 6 = Sunday (chrono's num_days_from_monday convention)
  smtp_day_of_week: number;
  smtp_day_of_month: number;
  has_smtp_password: boolean;
  /** Consecutive HTTP failures before a "target is down" alert fires. */
  failure_alert_threshold: number;
  ssl_alert_threshold_days: number;
  domain_alert_threshold_days: number;
  /** How long check history is kept before being pruned; 0 = keep forever. */
  history_retention_days: number;
}

export type UpdateSettingsInput = Omit<AppSettings, "has_smtp_password">;
