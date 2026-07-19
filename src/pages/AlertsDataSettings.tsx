import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { ArrowLeft } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { ExportDomainsDialog } from "@/components/export-domains-dialog";
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
  failure_alert_threshold: 2,
  response_time_alert_threshold_ms: 0,
  ssl_alert_threshold_days: 14,
  domain_alert_threshold_days: 30,
  history_retention_days: 90,
};

export function AlertsDataSettingsPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [saving, setSaving] = useState(false);
  const [testingNotification, setTestingNotification] = useState(false);
  const [importing, setImporting] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [exportDialogOpen, setExportDialogOpen] = useState(false);
  const [clearAllConfirmOpen, setClearAllConfirmOpen] = useState(false);

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
      toast.success(t("settings.saved"));
    } catch (err) {
      toast.error(`${t("settings.saveFailed")}: ${String(err)}`);
    } finally {
      setSaving(false);
    }
  };

  const handleExport = async (ids?: number[]) => {
    try {
      const path = await api.exportDomains(ids);
      if (path) toast.success(`${t("settings.exportSuccess")} ${path}`);
    } catch (err) {
      toast.error(`${t("settings.exportFailed")}: ${String(err)}`);
    }
  };

  const handleImport = async () => {
    setImporting(true);
    try {
      const result = await api.importDomains();
      if (result) {
        const skippedSuffix = result.skipped > 0 ? `, ${result.skipped} ${t("settings.importSkipped")}` : "";
        toast.success(`${t("settings.importSuccess")} ${result.imported}${skippedSuffix}`);
      }
    } catch (err) {
      toast.error(`${t("settings.importFailed")}: ${String(err)}`);
    } finally {
      setImporting(false);
    }
  };

  const handleClearAll = async () => {
    setClearing(true);
    try {
      await api.clearAllTargets();
      toast.success(t("settings.clearAllDomainsSuccess"));
    } catch (err) {
      toast.error(`${t("settings.clearAllDomainsFailed")}: ${String(err)}`);
    } finally {
      setClearing(false);
    }
  };

  const handleTestNotification = async () => {
    setTestingNotification(true);
    try {
      await api.sendTestNotification();
    } catch (err) {
      toast.error(`${t("settings.testNotificationFailed")}: ${String(err)}`);
    } finally {
      setTestingNotification(false);
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <div className="flex items-center gap-2">
        <Button variant="ghost" size="icon-sm" onClick={() => navigate("/settings")}>
          <ArrowLeft className="size-4" />
        </Button>
        <div className="flex flex-col">
          <h1 className="text-lg font-semibold tracking-tight">{t("settings.alertsData")}</h1>
          <span className="text-xs text-muted-foreground">{t("settings.alertsDataDesc")}</span>
        </div>
      </div>

      <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="grid gap-1.5">
            <Label>{t("settings.failureThreshold")}</Label>
            <Input
              type="number"
              min={1}
              value={settings.failure_alert_threshold}
              onChange={(e) => setSettings((s) => ({ ...s, failure_alert_threshold: Number(e.target.value) }))}
            />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("settings.responseTimeThreshold")}</Label>
            <Input
              type="number"
              min={0}
              value={settings.response_time_alert_threshold_ms}
              onChange={(e) =>
                setSettings((s) => ({ ...s, response_time_alert_threshold_ms: Number(e.target.value) }))
              }
            />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("settings.historyRetention")}</Label>
            <Input
              type="number"
              min={0}
              value={settings.history_retention_days}
              onChange={(e) => setSettings((s) => ({ ...s, history_retention_days: Number(e.target.value) }))}
            />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("settings.sslThreshold")}</Label>
            <Input
              type="number"
              min={1}
              value={settings.ssl_alert_threshold_days}
              onChange={(e) => setSettings((s) => ({ ...s, ssl_alert_threshold_days: Number(e.target.value) }))}
            />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("settings.domainThreshold")}</Label>
            <Input
              type="number"
              min={1}
              value={settings.domain_alert_threshold_days}
              onChange={(e) => setSettings((s) => ({ ...s, domain_alert_threshold_days: Number(e.target.value) }))}
            />
          </div>
        </div>
        <div className="flex gap-2">
          <Button onClick={handleSave} disabled={saving}>
            {t("settings.save")}
          </Button>
          <Button variant="outline" onClick={handleTestNotification} disabled={testingNotification}>
            {t("settings.testNotification")}
          </Button>
        </div>
      </div>

      <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
        <div className="flex flex-col">
          <span className="text-sm font-medium">{t("settings.domainsImportExport")}</span>
          <span className="text-xs text-muted-foreground">{t("settings.domainsImportExportDesc")}</span>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => setExportDialogOpen(true)}>
            {t("settings.exportDomains")}
          </Button>
          <Button variant="outline" onClick={handleImport} disabled={importing}>
            {t("settings.importDomains")}
          </Button>
          <Button variant="destructive" onClick={() => setClearAllConfirmOpen(true)} disabled={clearing}>
            {t("settings.clearAllDomains")}
          </Button>
        </div>
      </div>

      <ExportDomainsDialog open={exportDialogOpen} onOpenChange={setExportDialogOpen} onExport={handleExport} />

      <ConfirmDialog
        open={clearAllConfirmOpen}
        onOpenChange={setClearAllConfirmOpen}
        title={t("common.confirmTitle")}
        description={t("settings.clearAllDomainsConfirm")}
        confirmLabel={t("settings.clearAllDomains")}
        onConfirm={handleClearAll}
      />
    </div>
  );
}
