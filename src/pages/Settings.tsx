import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useTheme } from "next-themes";
import { ChevronRight, Monitor, Moon, Sun } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { AppSettings } from "@/types/settings";

const THEME_OPTIONS = [
  { value: "light", icon: Sun, labelKey: "theme.light" as const },
  { value: "dark", icon: Moon, labelKey: "theme.dark" as const },
  { value: "system", icon: Monitor, labelKey: "theme.system" as const },
];

function segmentClass(selected: boolean) {
  return cn(
    "flex h-7 flex-1 items-center justify-center gap-1.5 rounded-md px-2 text-xs leading-none font-medium transition-colors",
    selected
      ? "bg-white text-foreground shadow-sm dark:bg-white/20"
      : "text-muted-foreground hover:text-foreground",
  );
}

const DEFAULT_SETTINGS: AppSettings = {
  notifications_enabled: false,
  smtp_enabled: false,
  smtp_host: "smtp.gmail.com",
  smtp_port: 587,
  smtp_sender_email: "",
  smtp_recipient_email: "",
  smtp_frequency: "monthly",
  smtp_day_of_week: 0,
  smtp_day_of_month: 1,
  has_smtp_password: false,
  failure_alert_threshold: 2,
  response_time_alert_threshold_ms: 0,
  ssl_alert_threshold_days: 14,
  domain_alert_threshold_days: 30,
  history_retention_days: 90,
};

function SettingsSection({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
      <div className="flex flex-col gap-0.5">
        <span className="text-sm font-medium">{title}</span>
        {description && <span className="text-xs text-muted-foreground">{description}</span>}
      </div>
      {children}
    </div>
  );
}

function SettingsNavRow({
  title,
  description,
  badge,
  onClick,
}: {
  title: string;
  description: string;
  badge?: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex items-center justify-between rounded-xl border border-border bg-card p-4 text-left transition-colors hover:bg-accent/50"
    >
      <div className="flex flex-col gap-0.5">
        <span className="text-sm font-medium">{title}</span>
        <span className="text-xs text-muted-foreground">{description}</span>
      </div>
      <div className="flex items-center gap-2">
        {badge && <Badge variant="secondary">{badge}</Badge>}
        <ChevronRight className="size-4 text-muted-foreground" />
      </div>
    </button>
  );
}

export function SettingsPage() {
  const navigate = useNavigate();
  const { t, locale, setLocale } = useTranslation();
  const { theme, setTheme } = useTheme();
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [autostart, setAutostart] = useState(false);

  useEffect(() => {
    api.getSettings().then(setSettings).catch(() => toast.error(t("settings.saveFailed")));
    api.isAutostartEnabled().then(setAutostart).catch(() => {});
  }, [t]);

  const handleAutostartToggle = async (checked: boolean) => {
    try {
      if (checked) {
        const needsApproval = await api.enableAutostart();
        // enable_autostart already opens System Settings > Login Items
        // itself when approval is needed; the action button here just
        // covers the case where that window got closed or missed.
        if (needsApproval) {
          toast.info(t("settings.autostartNeedsApproval"), {
            action: { label: t("settings.openSettings"), onClick: () => api.enableAutostart() },
          });
        }
      } else {
        await api.disableAutostart();
      }
      setAutostart(checked);
    } catch (err) {
      toast.error(String(err));
    }
  };

  const handleNotificationsToggle = async (checked: boolean) => {
    const previous = settings;
    const updated = { ...settings, notifications_enabled: checked };
    setSettings(updated);
    try {
      await api.updateSettings({
        notifications_enabled: updated.notifications_enabled,
        smtp_enabled: updated.smtp_enabled,
        smtp_host: updated.smtp_host,
        smtp_port: updated.smtp_port,
        smtp_sender_email: updated.smtp_sender_email,
        smtp_recipient_email: updated.smtp_recipient_email,
        smtp_frequency: updated.smtp_frequency,
        smtp_day_of_week: updated.smtp_day_of_week,
        smtp_day_of_month: updated.smtp_day_of_month,
        failure_alert_threshold: updated.failure_alert_threshold,
        response_time_alert_threshold_ms: updated.response_time_alert_threshold_ms,
        ssl_alert_threshold_days: updated.ssl_alert_threshold_days,
        domain_alert_threshold_days: updated.domain_alert_threshold_days,
        history_retention_days: updated.history_retention_days,
      });
      if (checked) {
        // There's no reliable way to read the real macOS permission state
        // from here (see open_notification_settings's doc comment), so
        // this fires a real notification — which triggers the native
        // permission prompt on first use — and always offers a direct link
        // to this app's Notifications settings pane either way.
        api.sendTestNotification().catch(() => {});
        toast.info(t("settings.notificationsPermissionHint"), {
          action: { label: t("settings.openSettings"), onClick: () => api.openNotificationSettings() },
        });
      }
    } catch (err) {
      toast.error(`${t("settings.saveFailed")}: ${String(err)}`);
      setSettings(previous);
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <h1 className="text-lg font-semibold tracking-tight">{t("settings.title")}</h1>

      <SettingsSection title={t("settings.general")}>
        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="text-sm">{t("settings.notifications")}</span>
            <span className="text-xs text-muted-foreground">{t("settings.notificationsDesc")}</span>
          </div>
          <Switch checked={settings.notifications_enabled} onCheckedChange={handleNotificationsToggle} />
        </div>
        {!settings.notifications_enabled && (
          <p className="rounded-lg bg-accent/50 px-3 py-2 text-xs text-muted-foreground">
            {t("settings.notificationsSuggestion")}
          </p>
        )}

        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="text-sm">{t("settings.autostart")}</span>
            <span className="text-xs text-muted-foreground">{t("settings.autostartDesc")}</span>
          </div>
          <Switch checked={autostart} onCheckedChange={handleAutostartToggle} />
        </div>
      </SettingsSection>

      <SettingsSection title={t("settings.appearance")}>
        <div className="flex items-center justify-between">
          <span className="text-sm">{t("settings.theme")}</span>
          <div className="flex items-center gap-0.5 rounded-lg bg-black/[0.06] p-0.5 dark:bg-white/10">
            {THEME_OPTIONS.map(({ value, icon: Icon, labelKey }) => (
              <button key={value} onClick={() => setTheme(value)} className={segmentClass(theme === value)}>
                <Icon className="size-3.5" />
                {t(labelKey)}
              </button>
            ))}
          </div>
        </div>

        <div className="flex items-center justify-between">
          <span className="text-sm">{t("settings.language")}</span>
          <div className="flex items-center gap-0.5 rounded-lg bg-black/[0.06] p-0.5 dark:bg-white/10">
            <button onClick={() => setLocale("vi")} className={segmentClass(locale === "vi")}>
              VI
            </button>
            <button onClick={() => setLocale("en")} className={segmentClass(locale === "en")}>
              EN
            </button>
          </div>
        </div>
      </SettingsSection>

      <SettingsNavRow
        title={t("settings.alertsData")}
        description={t("settings.alertsDataDesc")}
        onClick={() => navigate("/settings/alerts-data")}
      />

      <SettingsNavRow
        title={t("settings.smtp")}
        description={t("settings.smtpDesc")}
        badge={settings.smtp_enabled ? t("settings.on") : t("settings.off")}
        onClick={() => navigate("/settings/email-report")}
      />
    </div>
  );
}
