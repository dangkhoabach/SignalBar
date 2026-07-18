import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { listen } from "@tauri-apps/api/event";
import { ArrowLeft } from "lucide-react";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { api } from "@/lib/api";
import { cn, formatDateOnly, formatDateTime } from "@/lib/utils";
import { useTranslation } from "@/lib/i18n/context";
import type { TargetDetail as TargetDetailData } from "@/types/target";

function StatTile({
  label,
  value,
  small,
}: {
  label: string;
  value: React.ReactNode;
  small?: boolean;
}) {
  return (
    <div className="flex flex-col gap-1 rounded-xl border border-border bg-card px-4 py-3">
      <span className="text-xs text-muted-foreground">{label}</span>
      <div className={cn("font-semibold tabular-nums", small ? "text-sm" : "text-lg")}>{value}</div>
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

export function TargetDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [detail, setDetail] = useState<TargetDetailData | null>(null);
  const [notFound, setNotFound] = useState(false);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const data = await api.getTargetDetail(Number(id));
      setDetail(data);
    } catch {
      setNotFound(true);
    }
  }, [id]);

  useEffect(() => {
    load();
    const unlisten = listen("overview-updated", () => load());
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [load]);

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

  const { target, ssl_status, domain_status, uptime_24h_pct, uptime_7d_pct, history, resolved_ips } = detail;

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
        <Switch checked={target.enabled} onCheckedChange={handleToggleEnabled} />
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-6">
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
        <div className="col-span-2">
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
          />
        </div>
      </div>

      <LatencyChart history={history} title={t("detail.latencyChart")} />

      <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-4">
        <span className="text-sm font-medium">{t("detail.historyTitle")}</span>
        {history.length === 0 ? (
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
              {history.map((check) => (
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
    </div>
  );
}
