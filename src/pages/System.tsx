import { useEffect, useState } from "react";
import {
  Cpu,
  MemoryStick,
  HardDrive,
  MonitorSmartphone,
  Wifi,
  WifiOff,
  Network,
  Thermometer,
  Battery,
  BatteryCharging,
  Clock,
  ArrowDown,
  ArrowUp,
} from "lucide-react";
import { Line, LineChart, ResponsiveContainer, XAxis, YAxis } from "recharts";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";
import type { SystemStats } from "@/types/system";

const POLL_INTERVAL_MS = 2000;
/** 1 minute of trend at the 2s poll interval — enough to see a spike coming
 * without the sparkline turning into unreadable noise. */
const HISTORY_LENGTH = 30;

function barColor(percent: number) {
  if (percent >= 90) return "bg-destructive";
  if (percent >= 70) return "bg-yellow-500";
  return "bg-primary";
}

// Apple's own thermal throttling starts well above 90C, but 70/85 flags
// "running hot" early enough to be a useful heads-up in a monitoring UI.
function tempColor(celsius: number) {
  if (celsius >= 85) return "text-destructive";
  if (celsius >= 70) return "text-yellow-500";
  return "text-foreground";
}

function tempStrokeColor(celsius: number) {
  if (celsius >= 85) return "var(--destructive)";
  if (celsius >= 70) return "#eab308";
  return "var(--primary)";
}

function formatUptime(secs: number) {
  const days = Math.floor(secs / 86400);
  const hours = Math.floor((secs % 86400) / 3600);
  const minutes = Math.floor((secs % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function formatKbps(kbps: number) {
  if (kbps >= 1024) return `${(kbps / 1024).toFixed(1)} MB/s`;
  return `${kbps.toFixed(0)} KB/s`;
}

// Inverse of barColor: for a battery, a HIGH percentage is good and a LOW
// one is the warning, so "danger at the top end" would be backwards.
function batteryBarColor(percent: number) {
  if (percent <= 20) return "bg-destructive";
  if (percent <= 40) return "bg-yellow-500";
  return "bg-primary";
}

function Bar({ percent, colorFn = barColor }: { percent: number; colorFn?: (percent: number) => string }) {
  const clamped = Math.min(100, Math.max(0, percent));
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
      <div
        className={cn("h-full rounded-full transition-[width]", colorFn(clamped))}
        style={{ width: `${clamped}%` }}
      />
    </div>
  );
}

function Sparkline({ data, color }: { data: number[]; color: string }) {
  if (data.length < 2) return null;
  const points = data.map((v, i) => ({ i, v }));
  return (
    <div className="h-8 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ top: 2, right: 1, bottom: 0, left: 1 }}>
          <XAxis dataKey="i" hide />
          <YAxis hide domain={["dataMin", "dataMax"]} />
          <Line
            type="monotone"
            dataKey="v"
            stroke={color}
            strokeWidth={1.5}
            dot={false}
            isAnimationActive={false}
          />
        </LineChart>
      </ResponsiveContainer>
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
  children?: React.ReactNode;
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
  const [cpuHistory, setCpuHistory] = useState<number[]>([]);
  const [tempHistory, setTempHistory] = useState<number[]>([]);

  useEffect(() => {
    let cancelled = false;
    const poll = () => {
      api
        .getSystemStats()
        .then((s) => {
          if (cancelled) return;
          setStats(s);
          setCpuHistory((prev) => [...prev, s.cpu_percent].slice(-HISTORY_LENGTH));
          if (s.cpu_temp_celsius != null) {
            const temp = s.cpu_temp_celsius;
            setTempHistory((prev) => [...prev, temp].slice(-HISTORY_LENGTH));
          }
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
          <Sparkline data={cpuHistory} color="var(--primary)" />
        </StatCard>

        <StatCard
          icon={Thermometer}
          title={t("system.temperature")}
          right={
            stats.cpu_temp_celsius != null ? (
              <span className={cn("text-sm font-semibold", tempColor(stats.cpu_temp_celsius))}>
                {stats.cpu_temp_celsius.toFixed(0)}°C
              </span>
            ) : undefined
          }
        >
          {stats.cpu_temp_celsius != null ? (
            <Bar percent={stats.cpu_temp_celsius} />
          ) : (
            <span className="text-xs text-muted-foreground">{t("system.notAvailable")}</span>
          )}
          {stats.fan_rpms.length > 0 && (
            <div className="flex items-center gap-3 pt-1">
              {stats.fan_rpms.map((rpm, i) => (
                <span key={i} className="text-xs text-muted-foreground">
                  {t("system.fan")} {stats.fan_rpms.length > 1 ? i + 1 : ""} {Math.round(rpm)} RPM
                </span>
              ))}
            </div>
          )}
          {stats.cpu_temp_celsius != null && (
            <Sparkline data={tempHistory} color={tempStrokeColor(stats.cpu_temp_celsius)} />
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

        {stats.battery_percent != null && (
          <StatCard
            icon={stats.battery_charging ? BatteryCharging : Battery}
            title={t("system.battery")}
            right={<span className="text-sm font-semibold">{stats.battery_percent.toFixed(0)}%</span>}
          >
            <Bar percent={stats.battery_percent} colorFn={batteryBarColor} />
            <span className="text-xs text-muted-foreground">
              {stats.battery_charging ? t("system.charging") : t("system.onBattery")}
            </span>
          </StatCard>
        )}

        <StatCard
          icon={Clock}
          title={t("system.uptime")}
          right={<span className="text-sm font-semibold">{formatUptime(stats.uptime_secs)}</span>}
        />

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
              <div className="flex items-center gap-3 pt-0.5">
                <span className="flex items-center gap-1 text-xs text-muted-foreground">
                  <ArrowDown className="size-3" />
                  {formatKbps(stats.network_download_kbps)}
                </span>
                <span className="flex items-center gap-1 text-xs text-muted-foreground">
                  <ArrowUp className="size-3" />
                  {formatKbps(stats.network_upload_kbps)}
                </span>
              </div>
            </div>
          ) : (
            <span className="text-xs text-muted-foreground">{t("system.notAvailable")}</span>
          )}
        </StatCard>
      </div>
    </div>
  );
}
