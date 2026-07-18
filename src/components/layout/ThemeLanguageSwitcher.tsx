import { useTheme } from "next-themes";
import { Monitor, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useTranslation } from "@/lib/i18n/context";
import { cn } from "@/lib/utils";

const THEME_OPTIONS = [
  { value: "light", icon: Sun, labelKey: "theme.light" as const },
  { value: "dark", icon: Moon, labelKey: "theme.dark" as const },
  { value: "system", icon: Monitor, labelKey: "theme.system" as const },
];

export function ThemeLanguageSwitcher() {
  const { theme, setTheme } = useTheme();
  const { locale, setLocale, t } = useTranslation();

  return (
    <div className="flex flex-col gap-2 px-2">
      <div className="flex items-center gap-0.5 rounded-lg bg-muted p-0.5">
        {THEME_OPTIONS.map(({ value, icon: Icon, labelKey }) => (
          <button
            key={value}
            title={t(labelKey)}
            onClick={() => setTheme(value)}
            className={cn(
              "flex flex-1 items-center justify-center rounded-md py-1 transition-colors",
              theme === value
                ? "bg-background text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            <Icon className="size-3.5" />
          </button>
        ))}
      </div>

      <div className="flex items-center gap-0.5 rounded-lg bg-muted p-0.5">
        <Button
          variant={locale === "vi" ? "secondary" : "ghost"}
          size="xs"
          className="flex-1"
          onClick={() => setLocale("vi")}
        >
          VI
        </Button>
        <Button
          variant={locale === "en" ? "secondary" : "ghost"}
          size="xs"
          className="flex-1"
          onClick={() => setLocale("en")}
        >
          EN
        </Button>
      </div>
    </div>
  );
}
