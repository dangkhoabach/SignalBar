import { useEffect, useState } from "react";
import { Cpu, MemoryStick, HardDrive, MonitorSmartphone, Wifi, WifiOff, Network } from "lucide-react";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import type { SystemStats } from "@/types/system";

const POLL_INTERVAL_MS = 2000;

function barColor(percent: number) {
  if (percent >= 90) return "bg-destructive";
  if (percent >= 70) return "bg-yellow-500";
  return "bg-primary";
}

function Bar({ percent }: { percent: number }) {
  const clamped = Math.min(100, Math.max(0, percent));
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
      <div
        className={cn("h-full rounded-full transition-[width]", barColor(clamped))}
        style={{ width: `${clamped}%` }}
      />
    </div>
  );
}

function StatCard({
  icon: Icon,
  title,
  right,
  children,
}: {
  icon: React.ElementType;
  title: string;
  right?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Icon className="size-4 text-muted-foreground" />
          <span className="text-sm font-medium">{title}</span>
        </div>
        {right}
      </div>
      {children}
    </div>
  );
}

export function SystemPage() {
  const { t } = useTranslation();
  const [stats, setStats] = useState<SystemStats | null>(null);

  useEffect(() => {
    let cancelled = false;
    const poll = () => {
      api
        .getSystemStats()
        .then((s) => {
          if (!cancelled) setStats(s);
        })
        .catch(() => {});
    };
    poll();
    const interval = setInterval(poll, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  if (!stats) {
    return (
      <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
        <h1 className="text-lg font-semibold tracking-tight">{t("system.title")}</h1>
      </div>
    );
  }

  const ramPercent = stats.ram_total_mb > 0 ? (stats.ram_used_mb / stats.ram_total_mb) * 100 : 0;
  const swapPercent = stats.swap_total_mb > 0 ? (stats.swap_used_mb / stats.swap_total_mb) * 100 : 0;
  const diskPercent = stats.disk_total_gb > 0 ? (stats.disk_used_gb / stats.disk_total_gb) * 100 : 0;

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <h1 className="text-lg font-semibold tracking-tight">{t("system.title")}</h1>

      <div className="grid grid-cols-2 gap-4">
        <StatCard icon={Cpu} title={t("system.cpu")} right={<span className="text-sm font-semibold">{stats.cpu_percent.toFixed(0)}%</span>}>
          <Bar percent={stats.cpu_percent} />
          {stats.cpu_cores.length > 1 && (
            <div className="flex flex-col gap-1.5 pt-1">
              <span className="text-xs text-muted-foreground">{t("system.cpuCores")}</span>
              <div className="grid grid-cols-4 gap-1.5">
                {stats.cpu_cores.map((core, i) => (
                  <div key={i} className="h-1.5 overflow-hidden rounded-full bg-muted">
                    <div
                      className={cn("h-full rounded-full", barColor(core))}
                      style={{ width: `${Math.min(100, Math.max(0, core))}%` }}
                    />
                  </div>
                ))}
              </div>
            </div>
          )}
        </StatCard>

        <StatCard
          icon={MemoryStick}
          title={t("system.ram")}
          right={
            <span className="text-sm font-semibold">
              {(stats.ram_used_mb / 1024).toFixed(1)} / {(stats.ram_total_mb / 1024).toFixed(1)} GB
            </span>
          }
        >
          <Bar percent={ramPercent} />
          {stats.swap_total_mb > 0 && (
            <div className="flex flex-col gap-1 pt-1">
              <div className="flex items-center justify-between text-xs text-muted-foreground">
                <span>{t("system.swap")}</span>
                <span>
                  {(stats.swap_used_mb / 1024).toFixed(1)} / {(stats.swap_total_mb / 1024).toFixed(1)} GB
                </span>
              </div>
              <Bar percent={swapPercent} />
            </div>
          )}
        </StatCard>

        <StatCard
          icon={HardDrive}
          title={t("system.disk")}
          right={
            <span className="text-sm font-semibold">
              {stats.disk_used_gb.toFixed(0)} / {stats.disk_total_gb.toFixed(0)} GB
            </span>
          }
        >
          <Bar percent={diskPercent} />
        </StatCard>

        <StatCard
          icon={MonitorSmartphone}
          title={stats.gpu_name ?? t("system.gpu")}
          right={
            stats.gpu_percent != null ? (
              <span className="text-sm font-semibold">{stats.gpu_percent.toFixed(0)}%</span>
            ) : undefined
          }
        >
          {stats.gpu_percent != null ? (
            <Bar percent={stats.gpu_percent} />
          ) : (
            <span className="text-xs text-muted-foreground">{t("system.notAvailable")}</span>
          )}
        </StatCard>

        <StatCard
          icon={stats.network_connected ? (stats.network_type === "Wi-Fi" ? Wifi : Network) : WifiOff}
          title={t("system.network")}
          right={
            <span
              className={cn(
                "text-sm font-semibold",
                stats.network_connected ? "text-success" : "text-destructive",
              )}
            >
              {stats.network_connected ? t("system.connected") : t("system.disconnected")}
            </span>
          }
        >
          {stats.network_connected ? (
            <div className="flex flex-col gap-0.5">
              <span className="text-xs text-muted-foreground">
                {stats.network_name ? `${stats.network_type} · ${stats.network_name}` : stats.network_type}
              </span>
              {stats.network_local_ip && (
                <span className="text-xs text-muted-foreground">
                  {t("system.localIp")}: {stats.network_local_ip}
                </span>
              )}
            </div>
          ) : (
            <span className="text-xs text-muted-foreground">{t("system.notAvailable")}</span>
          )}
        </StatCard>
      </div>
    </div>
  );
}
