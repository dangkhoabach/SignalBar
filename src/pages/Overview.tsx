import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { listen } from "@tauri-apps/api/event";
import { Plus, Trash2, Pencil, Globe, ShieldCheck, Clock } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { TargetFormDialog } from "@/components/target-form-dialog";
import { cn } from "@/lib/utils";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { TargetFormValues } from "@/lib/schemas";
import type { Target, TargetOverview } from "@/types/target";

function StatusDot({ overview }: { overview: TargetOverview }) {
  if (!overview.latest_check) {
    return <span className="size-2.5 rounded-full bg-muted-foreground/40" />;
  }
  return (
    <span
      className={cn(
        "size-2.5 rounded-full",
        overview.latest_check.success ? "bg-success" : "bg-destructive",
      )}
    />
  );
}

function TargetRow({
  overview,
  onEdit,
  onDelete,
}: {
  overview: TargetOverview;
  onEdit: (t: Target) => void;
  onDelete: (id: number) => void;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { target, latest_check, ssl_status, uptime_24h_pct } = overview;
  return (
    <div
      className="group flex cursor-pointer items-center gap-3 px-4 py-3 transition-colors hover:bg-accent/50"
      onClick={() => navigate(`/targets/${target.id}`)}
    >
      <StatusDot overview={overview} />

      <div className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-sm font-medium">{target.name}</span>
        <span className="truncate text-xs text-muted-foreground">{target.url}</span>
      </div>

      <div className="hidden items-center gap-4 text-xs text-muted-foreground sm:flex">
        {uptime_24h_pct != null && (
          <span className="flex items-center gap-1">
            <Globe className="size-3.5" />
            {uptime_24h_pct.toFixed(0)}% {t("overview.uptime")}
          </span>
        )}
        {latest_check?.response_time_ms != null && (
          <span className="flex items-center gap-1">
            <Clock className="size-3.5" />
            {latest_check.response_time_ms}ms
          </span>
        )}
        {ssl_status?.expiry_date && (
          <span className="flex items-center gap-1">
            <ShieldCheck className="size-3.5" />
            {ssl_status.expiry_date}
          </span>
        )}
      </div>

      {!latest_check ? (
        <Badge variant="secondary">{t("overview.status.unchecked")}</Badge>
      ) : latest_check.success ? (
        <Badge className="bg-success text-white">{t("overview.status.up")}</Badge>
      ) : (
        <Badge variant="destructive">{t("overview.status.down")}</Badge>
      )}

      <div className="flex items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={(e) => {
            e.stopPropagation();
            onEdit(target);
          }}
        >
          <Pencil className="size-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={(e) => {
            e.stopPropagation();
            onDelete(target.id);
          }}
        >
          <Trash2 className="size-3.5" />
        </Button>
      </div>
    </div>
  );
}

export function OverviewPage() {
  const { t } = useTranslation();
  const [overview, setOverview] = useState<TargetOverview[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingTarget, setEditingTarget] = useState<Target | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await api.getOverview();
      setOverview(data);
    } catch (err) {
      toast.error(`${t("toast.loadFailed")}: ${String(err)}`);
    } finally {
      setLoading(false);
    }
  }, [t]);

  useEffect(() => {
    load();
    const unlisten = listen("overview-updated", () => load());
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [load]);

  const handleAdd = () => {
    setEditingTarget(null);
    setDialogOpen(true);
  };

  const handleEdit = (target: Target) => {
    setEditingTarget(target);
    setDialogOpen(true);
  };

  const handleDelete = async (id: number) => {
    try {
      await api.deleteTarget(id);
      toast.success(t("toast.deleteSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.deleteFailed")}: ${String(err)}`);
    }
  };

  const handleSubmit = async (values: TargetFormValues) => {
    const payload = {
      name: values.name,
      url: values.url,
      group_tag: values.group_tag || null,
      check_interval_secs: values.check_interval_secs,
      check_http: values.check_http,
      expected_status: values.expected_status,
      check_ssl: values.check_ssl,
      check_domain: values.check_domain,
      custom_path: values.custom_path || null,
      expected_body_contains: values.expected_body_contains || null,
    };
    try {
      if (editingTarget) {
        await api.updateTarget({ ...payload, id: editingTarget.id, enabled: editingTarget.enabled });
        toast.success(t("toast.updateSuccess"));
      } else {
        await api.addTarget(payload);
        toast.success(t("toast.addSuccess"));
      }
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold tracking-tight">{t("overview.title")}</h1>
        <Button onClick={handleAdd}>
          <Plus className="size-4" />
          {t("overview.addTarget")}
        </Button>
      </div>

      {loading ? (
        <p className="text-sm text-muted-foreground">{t("overview.loading")}</p>
      ) : overview.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 rounded-2xl border border-dashed border-border py-16 text-center">
          <p className="text-sm text-muted-foreground">{t("overview.empty")}</p>
          <Button variant="outline" onClick={handleAdd}>
            <Plus className="size-4" />
            {t("overview.addFirstTarget")}
          </Button>
        </div>
      ) : (
        <div className="overflow-hidden rounded-2xl border border-border bg-card divide-y divide-border">
          {overview.map((row) => (
            <TargetRow
              key={row.target.id}
              overview={row}
              onEdit={handleEdit}
              onDelete={handleDelete}
            />
          ))}
        </div>
      )}

      <TargetFormDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        editingTarget={editingTarget}
        onSubmit={handleSubmit}
      />
    </div>
  );
}
