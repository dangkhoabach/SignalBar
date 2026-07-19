import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { listen } from "@tauri-apps/api/event";
import {
  ArrowLeft,
  AlertTriangle,
  MoreVertical,
  RefreshCw,
  PauseCircle,
  PlayCircle,
  Pencil,
  Trash2,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import { toast } from "sonner";
import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { TargetFormDialog } from "@/components/target-form-dialog";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { PauseTargetDialog } from "@/components/pause-target-dialog";
import { api } from "@/lib/api";
import { cn, formatDateOnly, formatDateTime, isPaused, pausedTooltip } from "@/lib/utils";
import { useTranslation } from "@/lib/i18n/context";
import type { TargetFormValues } from "@/lib/schemas";
import type { CheckResult, Incident, TargetDetail as TargetDetailData } from "@/types/target";

/** Local calendar date ("YYYY-MM-DD") for `date`, offset by `deltaDays`. */
function shiftDate(date: string, deltaDays: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const shifted = new Date(y, m - 1, d + deltaDays);
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${shifted.getFullYear()}-${pad(shifted.getMonth() + 1)}-${pad(shifted.getDate())}`;
}

function todayLocalDate(): string {
  const now = new Date();
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** Converts a local calendar date into the [start, end) UTC range `checked_at`
 * is stored in, so the day boundary matches the user's own timezone. */
function localDateToUtcRange(date: string): { start: string; end: string } {
  const [y, m, d] = date.split("-").map(Number);
  const toSqlUtc = (local: Date) => local.toISOString().slice(0, 19).replace("T", " ");
  return {
    start: toSqlUtc(new Date(y, m - 1, d, 0, 0, 0)),
    end: toSqlUtc(new Date(y, m - 1, d + 1, 0, 0, 0)),
  };
}

function StatTile({
  label,
  value,
  small,
  wrap,
  className,
}: {
  label: string;
  value: React.ReactNode;
  small?: boolean;
  /** Allows multi-line content (e.g. a list of IPs) instead of truncating to one line. */
  wrap?: boolean;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex min-w-0 flex-col gap-1 rounded-xl border border-border bg-card px-4 py-3",
        className,
      )}
    >
      <span className="truncate text-xs text-muted-foreground">{label}</span>
      <div
        className={cn(
          "font-semibold tabular-nums",
          small ? "text-sm" : "text-lg",
          wrap ? "min-w-0" : "truncate",
        )}
      >
        {value}
      </div>
    </div>
  );
}

function LatencyChart({ history, title }: { history: TargetDetailData["history"]; title: string }) {
  const data = [...history]
    .reverse()
    .filter((c) => c.response_time_ms != null)
    .map((c) => ({ time: c.checked_at, ms: c.response_time_ms as number }));

  if (data.length === 0) return null;

  return (
    <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-4">
      <span className="text-sm font-medium">{title}</span>
      <div className="h-48">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={data} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="var(--border)" />
            <XAxis dataKey="time" tick={false} axisLine={{ stroke: "var(--border)" }} tickLine={false} />
            <YAxis
              width={40}
              tick={{ fill: "var(--muted-foreground)", fontSize: 11 }}
              axisLine={false}
              tickLine={false}
            />
            <Tooltip
              contentStyle={{
                background: "var(--popover)",
                border: "1px solid var(--border)",
                borderRadius: "var(--radius-md)",
                fontSize: 12,
              }}
              labelFormatter={(label) => formatDateTime(new Date(label + "Z"))}
              formatter={(value) => [`${value}ms`, "Latency"]}
            />
            <Line
              type="monotone"
              dataKey="ms"
              stroke="var(--primary)"
              strokeWidth={2}
              dot={false}
              activeDot={{ r: 4 }}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

function formatDuration(startIso: string, endIso: string | null): string {
  const start = new Date(startIso + "Z");
  const end = endIso ? new Date(endIso + "Z") : new Date();
  const minutes = Math.max(0, Math.round((end.getTime() - start.getTime()) / 60000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const remaining = minutes % 60;
  if (hours < 24) return `${hours}h${remaining ? ` ${remaining}m` : ""}`;
  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}

function IncidentsCard({ incidents, title, ongoingLabel, noneLabel }: {
  incidents: Incident[];
  title: string;
  ongoingLabel: string;
  noneLabel: string;
}) {
  return (
    <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-4">
      <span className="text-sm font-medium">{title}</span>
      {incidents.length === 0 ? (
        <p className="text-sm text-muted-foreground">{noneLabel}</p>
      ) : (
        <div className="flex flex-col divide-y divide-border">
          {incidents.map((incident) => (
            <div key={incident.started_at} className="flex items-start gap-3 py-2.5 first:pt-0 last:pb-0">
              <AlertTriangle
                className={cn("mt-0.5 size-4 shrink-0", incident.ended_at ? "text-muted-foreground" : "text-destructive")}
              />
              <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                <div className="flex flex-wrap items-center gap-2 text-xs">
                  <span className="font-medium text-foreground">
                    {formatDateTime(new Date(incident.started_at + "Z"))}
                  </span>
                  <span className="text-muted-foreground">
                    {incident.ended_at ? `→ ${formatDateTime(new Date(incident.ended_at + "Z"))}` : ongoingLabel}
                  </span>
                  <Badge variant={incident.ended_at ? "secondary" : "destructive"}>
                    {formatDuration(incident.started_at, incident.ended_at)}
                  </Badge>
                </div>
                {incident.error_message && (
                  <span className="truncate text-xs text-muted-foreground">{incident.error_message}</span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function TargetDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [detail, setDetail] = useState<TargetDetailData | null>(null);
  const [notFound, setNotFound] = useState(false);
  const [checking, setChecking] = useState(false);
  const [editDialogOpen, setEditDialogOpen] = useState(false);
  const [pendingDelete, setPendingDelete] = useState(false);
  const [pendingPause, setPendingPause] = useState(false);
  const [selectedDate, setSelectedDate] = useState(todayLocalDate);
  const [dayHistory, setDayHistory] = useState<CheckResult[]>([]);
  const [dayHistoryLoading, setDayHistoryLoading] = useState(true);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const data = await api.getTargetDetail(Number(id));
      setDetail(data);
    } catch {
      setNotFound(true);
    }
  }, [id]);

  const loadDayHistory = useCallback(async () => {
    if (!id) return;
    setDayHistoryLoading(true);
    try {
      const { start, end } = localDateToUtcRange(selectedDate);
      const data = await api.getHistoryForDate(Number(id), start, end);
      setDayHistory(data);
    } catch (err) {
      toast.error(`${t("toast.loadFailed")}: ${String(err)}`);
    } finally {
      setDayHistoryLoading(false);
    }
  }, [id, selectedDate, t]);

  useEffect(() => {
    loadDayHistory();
  }, [loadDayHistory]);

  useEffect(() => {
    load();
    const unlisten = listen("overview-updated", () => {
      load();
      loadDayHistory();
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [load, loadDayHistory]);

  const handleToggleEnabled = async (enabled: boolean) => {
    if (!detail) return;
    const { target } = detail;
    try {
      await api.updateTarget({
        id: target.id,
        name: target.name,
        url: target.url,
        group_tag: target.group_tag,
        check_interval_secs: target.check_interval_secs,
        enabled,
        check_http: target.check_http,
        expected_status: target.expected_status,
        check_ssl: target.check_ssl,
        check_domain: target.check_domain,
        custom_path: target.custom_path,
        expected_body_contains: target.expected_body_contains,
      });
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  const handleCheckNow = async () => {
    if (!detail) return;
    setChecking(true);
    try {
      await api.checkTargetNow(detail.target.id);
      toast.success(t("toast.checkNowSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.checkNowFailed")}: ${String(err)}`);
    } finally {
      setChecking(false);
    }
  };

  const handleEditSubmit = async (values: TargetFormValues) => {
    if (!detail) return;
    try {
      await api.updateTarget({
        id: detail.target.id,
        enabled: detail.target.enabled,
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
      });
      toast.success(t("toast.updateSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  const handleConfirmDelete = async () => {
    if (!detail) return;
    try {
      await api.deleteTarget(detail.target.id);
      toast.success(t("toast.deleteSuccess"));
      navigate("/");
    } catch (err) {
      toast.error(`${t("toast.deleteFailed")}: ${String(err)}`);
    }
  };

  const handleConfirmPause = async (minutes?: number) => {
    if (!detail) return;
    try {
      await api.pauseTarget(detail.target.id, minutes);
      load();
    } catch (err) {
      toast.error(`${t("toast.pauseFailed")}: ${String(err)}`);
    }
  };

  const handleResume = async () => {
    if (!detail) return;
    try {
      await api.resumeTarget(detail.target.id);
      load();
    } catch (err) {
      toast.error(`${t("toast.resumeFailed")}: ${String(err)}`);
    }
  };

  if (notFound) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-3 pt-11">
        <p className="text-sm text-muted-foreground">{t("detail.notFound")}</p>
        <Button variant="outline" onClick={() => navigate("/")}>
          <ArrowLeft className="size-4" />
          {t("detail.back")}
        </Button>
      </div>
    );
  }

  if (!detail) return null;

  const { target, ssl_status, domain_status, uptime_24h_pct, uptime_7d_pct, history, resolved_ips, incidents } = detail;
  const paused = isPaused(target);

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <div className="flex items-center gap-2">
        <Button variant="ghost" size="icon-sm" onClick={() => navigate("/")}>
          <ArrowLeft className="size-4" />
        </Button>
        <div className="flex flex-1 flex-col">
          <h1 className="text-lg font-semibold tracking-tight">{target.name}</h1>
          <span className="text-xs text-muted-foreground">{target.url}</span>
        </div>
        {paused && (
          <Badge variant="secondary" title={pausedTooltip(target.paused_until!, t)}>
            <PauseCircle className="size-3" />
            {t("overview.paused")}
          </Badge>
        )}
        <Switch checked={target.enabled} onCheckedChange={handleToggleEnabled} />

        <DropdownMenu>
          <DropdownMenuTrigger render={<Button variant="ghost" size="icon-sm" />}>
            <MoreVertical className="size-3.5" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem disabled={checking} onClick={handleCheckNow}>
              <RefreshCw className={cn("size-3.5", checking && "animate-spin")} />
              {t("overview.checkNow")}
            </DropdownMenuItem>
            {paused ? (
              <DropdownMenuItem onClick={handleResume}>
                <PlayCircle className="size-3.5" />
                {t("overview.resume")}
              </DropdownMenuItem>
            ) : (
              <DropdownMenuItem onClick={() => setPendingPause(true)}>
                <PauseCircle className="size-3.5" />
                {t("overview.pause")}
              </DropdownMenuItem>
            )}
            <DropdownMenuItem onClick={() => setEditDialogOpen(true)}>
              <Pencil className="size-3.5" />
              {t("overview.edit")}
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={() => setPendingDelete(true)}>
              <Trash2 className="size-3.5" />
              {t("overview.delete")}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <StatTile
          label={t("detail.uptime24h")}
          value={uptime_24h_pct != null ? `${uptime_24h_pct.toFixed(1)}%` : "—"}
        />
        <StatTile
          label={t("detail.uptime7d")}
          value={uptime_7d_pct != null ? `${uptime_7d_pct.toFixed(1)}%` : "—"}
        />
        <StatTile
          label={t("detail.sslExpiry")}
          value={ssl_status?.expiry_date ? formatDateOnly(ssl_status.expiry_date) : "—"}
        />
        <StatTile
          label={t("detail.domainExpiry")}
          value={domain_status?.expiry_date ? formatDateOnly(domain_status.expiry_date) : "—"}
        />
        <StatTile
          label={t("detail.ipAddress")}
          value={
            resolved_ips.length > 0 ? (
              <div className="flex flex-wrap gap-x-3 gap-y-0.5">
                {resolved_ips.map((ip) => (
                  <span key={ip}>{ip}</span>
                ))}
              </div>
            ) : (
              "—"
            )
          }
          small
          wrap
          className="col-span-2"
        />
      </div>

      <LatencyChart history={history} title={t("detail.latencyChart")} />

      <IncidentsCard
        incidents={incidents}
        title={t("detail.incidentsTitle")}
        ongoingLabel={t("detail.incidentOngoing")}
        noneLabel={t("detail.noIncidents")}
      />

      <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-4">
        <div className="flex items-center justify-between gap-2">
          <span className="text-sm font-medium">{t("detail.historyTitle")}</span>
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="icon-sm" onClick={() => setSelectedDate((d) => shiftDate(d, -1))}>
              <ChevronLeft className="size-3.5" />
            </Button>
            <input
              type="date"
              value={selectedDate}
              max={todayLocalDate()}
              onChange={(e) => e.target.value && setSelectedDate(e.target.value)}
              className="h-8 rounded-lg border border-input bg-transparent px-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
            />
            <Button
              variant="ghost"
              size="icon-sm"
              disabled={selectedDate >= todayLocalDate()}
              onClick={() => setSelectedDate((d) => shiftDate(d, 1))}
            >
              <ChevronRight className="size-3.5" />
            </Button>
          </div>
        </div>
        {dayHistoryLoading ? (
          <p className="text-sm text-muted-foreground">{t("overview.loading")}</p>
        ) : dayHistory.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("detail.noHistory")}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("detail.col.time")}</TableHead>
                <TableHead>{t("detail.col.status")}</TableHead>
                <TableHead>{t("detail.col.latency")}</TableHead>
                <TableHead>{t("detail.col.error")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {dayHistory.map((check) => (
                <TableRow key={check.id}>
                  <TableCell className="text-xs text-muted-foreground">
                    {formatDateTime(new Date(check.checked_at + "Z"))}
                  </TableCell>
                  <TableCell>
                    {check.success ? (
                      <Badge className="bg-success text-white">{t("overview.status.up")}</Badge>
                    ) : (
                      <Badge variant="destructive">{t("overview.status.down")}</Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-xs">
                    {check.response_time_ms != null ? `${check.response_time_ms}ms` : "—"}
                  </TableCell>
                  <TableCell className="max-w-64 truncate text-xs text-muted-foreground">
                    {check.error_message ?? "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>

      <TargetFormDialog
        open={editDialogOpen}
        onOpenChange={setEditDialogOpen}
        editingTarget={target}
        onSubmit={handleEditSubmit}
      />

      <ConfirmDialog
        open={pendingDelete}
        onOpenChange={setPendingDelete}
        title={t("common.confirmTitle")}
        description={t("overview.deleteConfirm", { name: target.name })}
        confirmLabel={t("common.delete")}
        onConfirm={handleConfirmDelete}
      />

      <PauseTargetDialog
        open={pendingPause}
        onOpenChange={setPendingPause}
        targetName={target.name}
        onPause={handleConfirmPause}
      />
    </div>
  );
}
