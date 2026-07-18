import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
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
