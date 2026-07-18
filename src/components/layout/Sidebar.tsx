import { Activity } from "lucide-react";
import { NavLink } from "react-router";
import { cn } from "@/lib/utils";
import { useTranslation } from "@/lib/i18n/context";
import { ThemeLanguageSwitcher } from "@/components/layout/ThemeLanguageSwitcher";

export function Sidebar() {
  const { t } = useTranslation();
  const navItems = [
    { to: "/", label: t("nav.overview"), end: true },
    { to: "/settings", label: t("nav.settings"), end: true },
  ];

  return (
    <aside className="flex w-52 shrink-0 flex-col gap-1 border-r border-sidebar-border bg-sidebar pt-11 pb-4">
      <div className="mb-3 flex items-center gap-2 px-4">
        <Activity className="size-4 text-primary" />
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
                "rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors",
                isActive
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
              )
            }
          >
            {item.label}
          </NavLink>
        ))}
      </nav>

      <ThemeLanguageSwitcher />
    </aside>
  );
}
