import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { ChevronRight } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { AppSettings } from "@/types/settings";

const DEFAULT_SETTINGS: AppSettings = {
  notifications_enabled: true,
  smtp_enabled: false,
  smtp_host: "smtp.gmail.com",
  smtp_port: 587,
  smtp_sender_email: "",
  smtp_recipient_email: "",
  smtp_frequency: "monthly",
  smtp_day_of_week: 0,
  smtp_day_of_month: 1,
  has_smtp_password: false,
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

export function SettingsPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
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
        if (needsApproval) toast.info(t("settings.autostartNeedsApproval"));
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
      });
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

        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="text-sm">{t("settings.autostart")}</span>
            <span className="text-xs text-muted-foreground">{t("settings.autostartDesc")}</span>
          </div>
          <Switch checked={autostart} onCheckedChange={handleAutostartToggle} />
        </div>
      </SettingsSection>

      <button
        type="button"
        onClick={() => navigate("/settings/email-report")}
        className="flex items-center justify-between rounded-xl border border-border bg-card p-4 text-left transition-colors hover:bg-accent/50"
      >
        <div className="flex flex-col gap-0.5">
          <span className="text-sm font-medium">{t("settings.smtp")}</span>
          <span className="text-xs text-muted-foreground">{t("settings.smtpDesc")}</span>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant="secondary">
            {settings.smtp_enabled ? t("settings.on") : t("settings.off")}
          </Badge>
          <ChevronRight className="size-4 text-muted-foreground" />
        </div>
      </button>
    </div>
  );
}
