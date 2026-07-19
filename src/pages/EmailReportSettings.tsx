import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { ArrowLeft } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { AppSettings, SmtpFrequency } from "@/types/settings";

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
  failure_alert_threshold: 2,
  response_time_alert_threshold_ms: 0,
  ssl_alert_threshold_days: 14,
  domain_alert_threshold_days: 30,
  history_retention_days: 90,
};

const WEEKDAY_KEYS = [
  "settings.weekday.mon",
  "settings.weekday.tue",
  "settings.weekday.wed",
  "settings.weekday.thu",
  "settings.weekday.fri",
  "settings.weekday.sat",
  "settings.weekday.sun",
] as const;

export function EmailReportSettingsPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [smtpPassword, setSmtpPassword] = useState("");
  const [saving, setSaving] = useState(false);
  const [sendingTest, setSendingTest] = useState(false);

  useEffect(() => {
    api.getSettings().then(setSettings).catch(() => toast.error(t("settings.saveFailed")));
  }, [t]);

  const handleSave = async () => {
    setSaving(true);
    try {
      await api.updateSettings({
        notifications_enabled: settings.notifications_enabled,
        smtp_enabled: settings.smtp_enabled,
        smtp_host: settings.smtp_host,
        smtp_port: settings.smtp_port,
        smtp_sender_email: settings.smtp_sender_email,
        smtp_recipient_email: settings.smtp_recipient_email,
        smtp_frequency: settings.smtp_frequency,
        smtp_day_of_week: settings.smtp_day_of_week,
        smtp_day_of_month: settings.smtp_day_of_month,
        failure_alert_threshold: settings.failure_alert_threshold,
        response_time_alert_threshold_ms: settings.response_time_alert_threshold_ms,
        ssl_alert_threshold_days: settings.ssl_alert_threshold_days,
        domain_alert_threshold_days: settings.domain_alert_threshold_days,
        history_retention_days: settings.history_retention_days,
      });
      if (smtpPassword.trim()) {
        await api.saveSmtpPassword(smtpPassword.trim());
        setSmtpPassword("");
      }
      setSettings(await api.getSettings());
      toast.success(t("settings.saved"));
    } catch (err) {
      toast.error(`${t("settings.saveFailed")}: ${String(err)}`);
    } finally {
      setSaving(false);
    }
  };

  const handleSendTest = async () => {
    setSendingTest(true);
    try {
      await api.sendTestEmail();
      toast.success(t("settings.testEmailSent"));
    } catch (err) {
      toast.error(`${t("settings.testEmailFailed")}: ${String(err)}`);
    } finally {
      setSendingTest(false);
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <div className="flex items-center gap-2">
        <Button variant="ghost" size="icon-sm" onClick={() => navigate("/settings")}>
          <ArrowLeft className="size-4" />
        </Button>
        <div className="flex flex-col">
          <h1 className="text-lg font-semibold tracking-tight">{t("settings.smtp")}</h1>
          <span className="text-xs text-muted-foreground">{t("settings.smtpDesc")}</span>
        </div>
      </div>

      <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
        <div className="flex items-center justify-between">
          <span className="text-sm">{t("settings.smtpEnabled")}</span>
          <Switch
            checked={settings.smtp_enabled}
            onCheckedChange={(checked) => setSettings((s) => ({ ...s, smtp_enabled: checked }))}
          />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="grid gap-1.5">
            <Label>{t("settings.smtpHost")}</Label>
            <Input
              value={settings.smtp_host}
              onChange={(e) => setSettings((s) => ({ ...s, smtp_host: e.target.value }))}
            />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("settings.smtpPort")}</Label>
            <Input
              type="number"
              value={settings.smtp_port}
              onChange={(e) => setSettings((s) => ({ ...s, smtp_port: Number(e.target.value) }))}
            />
          </div>
        </div>

        <div className="grid gap-1.5">
          <Label>{t("settings.smtpSender")}</Label>
          <Input
            type="email"
            value={settings.smtp_sender_email}
            onChange={(e) => setSettings((s) => ({ ...s, smtp_sender_email: e.target.value }))}
          />
        </div>

        <div className="grid gap-1.5">
          <Label>{t("settings.smtpPassword")}</Label>
          <Input
            type="password"
            value={smtpPassword}
            onChange={(e) => setSmtpPassword(e.target.value)}
            placeholder={
              settings.has_smtp_password ? "••••••••••••" : t("settings.smtpPasswordPlaceholder")
            }
          />
        </div>

        <div className="grid gap-1.5">
          <Label>{t("settings.smtpRecipient")}</Label>
          <Input
            type="email"
            value={settings.smtp_recipient_email}
            onChange={(e) => setSettings((s) => ({ ...s, smtp_recipient_email: e.target.value }))}
          />
        </div>

        <div className="grid gap-1.5">
          <Label>{t("settings.smtpFrequency")}</Label>
          <Select
            value={settings.smtp_frequency}
            onValueChange={(value) => setSettings((s) => ({ ...s, smtp_frequency: value as SmtpFrequency }))}
          >
            <SelectTrigger className="w-full">
              <SelectValue>{(value: SmtpFrequency) => t(`settings.frequency.${value}`)}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="daily">{t("settings.frequency.daily")}</SelectItem>
              <SelectItem value="weekly">{t("settings.frequency.weekly")}</SelectItem>
              <SelectItem value="monthly">{t("settings.frequency.monthly")}</SelectItem>
            </SelectContent>
          </Select>
        </div>

        {settings.smtp_frequency === "weekly" && (
          <div className="grid gap-1.5">
            <Label>{t("settings.smtpDayOfWeek")}</Label>
            <Select
              value={String(settings.smtp_day_of_week)}
              onValueChange={(value) => setSettings((s) => ({ ...s, smtp_day_of_week: Number(value) }))}
            >
              <SelectTrigger className="w-full">
                <SelectValue>{(value: string) => t(WEEKDAY_KEYS[Number(value)])}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                {WEEKDAY_KEYS.map((key, i) => (
                  <SelectItem key={key} value={String(i)}>
                    {t(key)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}

        {settings.smtp_frequency === "monthly" && (
          <div className="grid gap-1.5">
            <Label>{t("settings.smtpDay")}</Label>
            <Input
              type="number"
              min={1}
              max={28}
              value={settings.smtp_day_of_month}
              onChange={(e) => setSettings((s) => ({ ...s, smtp_day_of_month: Number(e.target.value) }))}
            />
          </div>
        )}

        <div className="flex gap-2">
          <Button onClick={handleSave} disabled={saving}>
            {t("settings.save")}
          </Button>
          <Button
            variant="outline"
            onClick={handleSendTest}
            disabled={sendingTest || !settings.has_smtp_password}
          >
            {t("settings.sendTestEmail")}
          </Button>
        </div>
      </div>
    </div>
  );
}
