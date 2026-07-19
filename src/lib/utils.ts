import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";
import type { TranslationKey } from "@/lib/i18n/translations";
import type { Target } from "@/types/target";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function isPaused(target: Target): boolean {
  return !!target.paused_until && new Date(target.paused_until + "Z") > new Date();
}

/** The far-future sentinel `pause_target` writes for "paused indefinitely" (see commands.rs). */
const INDEFINITE_PAUSE_PREFIX = "9999-";

export function pausedTooltip(
  pausedUntil: string,
  t: (key: TranslationKey, vars?: Record<string, string | number>) => string,
): string {
  if (pausedUntil.startsWith(INDEFINITE_PAUSE_PREFIX)) return t("overview.pausedIndefinitely");
  return t("overview.pausedUntil", { time: formatDateTime(new Date(pausedUntil + "Z")) });
}

/** Formats a Date as "hh:mm:ss dd/MM/yyyy" (24h, zero-padded). */
export function formatDateTime(date: Date): string {
  const pad = (n: number) => n.toString().padStart(2, "0");
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  const day = `${pad(date.getDate())}/${pad(date.getMonth() + 1)}/${date.getFullYear()}`;
  return `${time} ${day}`;
}

/** Formats a "YYYY-MM-DD" date-only string (as stored for SSL/domain expiry) as "dd/MM/yyyy". */
export function formatDateOnly(isoDate: string): string {
  const [year, month, day] = isoDate.split("-");
  if (!year || !month || !day) return isoDate;
  return `${day}/${month}/${year}`;
}
