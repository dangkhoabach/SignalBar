import { useEffect, useState } from "react";
import { isEnabled as isAutostartEnabled, enable as enableAutostart, disable as disableAutostart } from "@tauri-apps/plugin-autostart";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
  const { t } = useTranslation();
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [smtpPassword, setSmtpPassword] = useState("");
  const [autostart, setAutostart] = useState(false);
  const [saving, setSaving] = useState(false);
  const [sendingTest, setSendingTest] = useState(false);

  useEffect(() => {
    api.getSettings().then(setSettings).catch(() => toast.error(t("settings.saveFailed")));
    isAutostartEnabled().then(setAutostart).catch(() => {});
  }, [t]);

  const handleAutostartToggle = async (checked: boolean) => {
    try {
      if (checked) {
        await enableAutostart();
      } else {
        await disableAutostart();
      }
      setAutostart(checked);
    } catch (err) {
      toast.error(String(err));
    }
  };

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
        smtp_day_of_month: settings.smtp_day_of_month,
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
      <h1 className="text-lg font-semibold tracking-tight">{t("settings.title")}</h1>

      <SettingsSection title={t("settings.general")}>
        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="text-sm">{t("settings.notifications")}</span>
            <span className="text-xs text-muted-foreground">{t("settings.notificationsDesc")}</span>
          </div>
          <Switch
            checked={settings.notifications_enabled}
            onCheckedChange={(checked) => setSettings((s) => ({ ...s, notifications_enabled: checked }))}
          />
        </div>

        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="text-sm">{t("settings.autostart")}</span>
            <span className="text-xs text-muted-foreground">{t("settings.autostartDesc")}</span>
          </div>
          <Switch checked={autostart} onCheckedChange={handleAutostartToggle} />
        </div>
      </SettingsSection>

      <SettingsSection title={t("settings.smtp")} description={t("settings.smtpDesc")}>
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
          <Label>{t("settings.smtpDay")}</Label>
          <Input
            type="number"
            min={1}
            max={28}
            value={settings.smtp_day_of_month}
            onChange={(e) => setSettings((s) => ({ ...s, smtp_day_of_month: Number(e.target.value) }))}
          />
        </div>

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
      </SettingsSection>
    </div>
  );
}
