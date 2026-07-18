import { Activity } from "lucide-react";
import { cn } from "@/lib/utils";
import { useTranslation } from "@/lib/i18n/context";
import { ThemeLanguageSwitcher } from "@/components/layout/ThemeLanguageSwitcher";

interface SidebarProps {
  activeItem: string;
}

export function Sidebar({ activeItem }: SidebarProps) {
  const { t } = useTranslation();
  const navItems = [{ id: "overview", label: t("nav.overview") }];

  return (
    <aside className="titlebar-drag-region flex w-52 shrink-0 flex-col gap-1 border-r border-sidebar-border bg-sidebar pt-11 pb-4">
      <div className="mb-3 flex items-center gap-2 px-4">
        <Activity className="size-4 text-primary" />
        <span className="text-sm font-semibold tracking-tight">{t("app.name")}</span>
      </div>

      <nav className="flex flex-1 flex-col gap-0.5 px-2">
        {navItems.map((item) => (
          <div
            key={item.id}
            className={cn(
              "titlebar-no-drag rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors",
              item.id === activeItem
                ? "bg-sidebar-accent text-sidebar-accent-foreground"
                : "text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
            )}
          >
            {item.label}
          </div>
        ))}
      </nav>

      <ThemeLanguageSwitcher />
    </aside>
  );
}
