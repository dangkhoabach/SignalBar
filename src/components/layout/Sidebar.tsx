import { useEffect, useState } from "react";
import { Cpu, LayoutGrid, Settings } from "lucide-react";
import { NavLink } from "react-router";
import { listen } from "@tauri-apps/api/event";
import { cn } from "@/lib/utils";
import { useTranslation } from "@/lib/i18n/context";
import { api } from "@/lib/api";
import appIcon from "@/app-icon.png";

export function Sidebar() {
  const { t } = useTranslation();
  const [downCount, setDownCount] = useState(0);

  useEffect(() => {
    const load = () => {
      api
        .getUptimeSummary()
        .then(([up, total]) => setDownCount(total - up))
        .catch(() => {});
    };
    load();
    const unlisten = listen("overview-updated", load);
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const navItems = [
    { to: "/", label: t("nav.overview"), icon: LayoutGrid, end: true, badge: downCount },
    { to: "/system", label: t("nav.system"), icon: Cpu, end: true },
    { to: "/settings", label: t("nav.settings"), icon: Settings, end: true },
  ];

  return (
    <aside className="flex w-52 shrink-0 flex-col gap-1 border-r border-sidebar-border bg-sidebar pt-11 pb-4">
      <div className="mb-3 flex items-center gap-2 px-4">
        <img src={appIcon} alt="" className="size-5 rounded-md" />
        <span className="text-sm font-semibold tracking-tight">{t("app.name")}</span>
      </div>

      <nav className="flex flex-1 flex-col gap-0.5 px-2">
        {navItems.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.end}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors",
                isActive
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
              )
            }
          >
            <item.icon className="size-4" />
            <span className="flex-1">{item.label}</span>
            {!!item.badge && (
              <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-semibold text-white">
                {item.badge}
              </span>
            )}
          </NavLink>
        ))}
      </nav>
    </aside>
  );
}
