export interface AppSettings {
  notifications_enabled: boolean;
  smtp_enabled: boolean;
  smtp_host: string;
  smtp_port: number;
  smtp_sender_email: string;
  smtp_recipient_email: string;
  smtp_day_of_month: number;
  has_smtp_password: boolean;
}

export type UpdateSettingsInput = Omit<AppSettings, "has_smtp_password">;
