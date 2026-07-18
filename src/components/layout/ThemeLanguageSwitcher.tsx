import { useTheme } from "next-themes";
import { Monitor, Moon, Sun } from "lucide-react";
import { useTranslation } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";

const THEME_OPTIONS = [
  { value: "light", icon: Sun, labelKey: "theme.light" as const },
  { value: "dark", icon: Moon, labelKey: "theme.dark" as const },
  { value: "system", icon: Monitor, labelKey: "theme.system" as const },
];

const segmentClass = (selected: boolean) =>
  cn(
    "flex h-6 flex-1 items-center justify-center rounded-md text-xs leading-none font-medium transition-colors",
    selected
      ? "bg-white text-foreground shadow-sm dark:bg-white/20"
      : "text-muted-foreground hover:text-foreground",
  );

export function ThemeLanguageSwitcher() {
  const { theme, setTheme } = useTheme();
  const { locale, setLocale, t } = useTranslation();

  return (
    <div className="flex flex-col gap-2 px-2">
      <div className="flex items-center gap-0.5 rounded-lg bg-black/[0.06] p-0.5 dark:bg-white/10">
        {THEME_OPTIONS.map(({ value, icon: Icon, labelKey }) => (
          <button
            key={value}
            title={t(labelKey)}
            onClick={() => setTheme(value)}
            className={segmentClass(theme === value)}
          >
            <Icon className="size-3" />
          </button>
        ))}
      </div>

      <div className="flex items-center gap-0.5 rounded-lg bg-black/[0.06] p-0.5 dark:bg-white/10">
        <button onClick={() => setLocale("vi")} className={segmentClass(locale === "vi")}>
          VI
        </button>
        <button onClick={() => setLocale("en")} className={segmentClass(locale === "en")}>
          EN
        </button>
      </div>
    </div>
  );
}
