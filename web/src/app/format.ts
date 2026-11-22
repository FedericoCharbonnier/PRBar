import { avatarColor } from "../ui/components/basics";
import type { Person } from "../ui/screens/types";

// Formato de textos compartido por los modelos (Format.swift de la app nativa). Fechas en milisegundos; el idioma y la
// zona horaria son parámetros para que los tests sean deterministas.

export interface Locale {
  /** BCP 47 ("en-US"). */
  locale?: string | undefined;
  timeZone?: string | undefined;
}

/** `acme/web-app` → `web-app`. */
export function repoName(repo: string): string {
  return repo.split("/").pop() || repo;
}

/** `acme/web-app#491` → `web-app#491`. */
export function shortRef(prId: string): string {
  const hash = prId.lastIndexOf("#");
  if (hash < 0) return prId;
  return repoName(prId.slice(0, hash)) + prId.slice(hash);
}

/** `acme/api#317` → `{repo: "acme/api", number: 317}`. */
export function splitPRId(prId: string): { repo: string; number: number } {
  const hash = prId.lastIndexOf("#");
  if (hash < 0) return { repo: prId, number: 0 };
  return { repo: prId.slice(0, hash), number: Number(prId.slice(hash + 1)) || 0 };
}

/** Edad de una fila: "now", "12 min", "2h", "3d", "5w". */
export function age(date: number, now: number): string {
  const seconds = Math.max(0, (now - date) / 1000);
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
  if (seconds < 7 * 86_400) return `${Math.floor(seconds / 86_400)}d`;
  return `${Math.floor(seconds / (7 * 86_400))}w`;
}

/** Estilo notificación: "now", "4m ago", "2h ago", "3d ago". */
export function ago(date: number, now: number): string {
  const seconds = Math.max(0, (now - date) / 1000);
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86_400)}d ago`;
}

/** "8:12 AM". */
export function time(date: number, l: Locale = {}): string {
  return new Intl.DateTimeFormat(l.locale ?? "en-US", { hour: "numeric", minute: "2-digit", timeZone: l.timeZone })
    .format(date);
}

function dayKey(date: number, timeZone: string | undefined): string {
  return new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", timeZone }).format(date);
}

/** "today at 8:12 AM" / "yesterday at 8:12 AM" / "Nov 18 at 8:12 AM". */
export function dayAndTime(date: number, now: number, l: Locale = {}): string {
  const clock = time(date, l);
  const day = dayKey(date, l.timeZone);
  if (day === dayKey(now, l.timeZone)) return `today at ${clock}`;
  if (day === dayKey(now - 86_400_000, l.timeZone)) return `yesterday at ${clock}`;
  const md = new Intl.DateTimeFormat(l.locale ?? "en-US", { month: "short", day: "numeric", timeZone: l.timeZone })
    .format(date);
  return `${md} at ${clock}`;
}

/** "Today 9:32 AM" / "Yesterday 9:32 AM" / "Nov 18 9:32 AM" (encabezado del chat). */
export function chatStamp(date: number, now: number, l: Locale = {}): string {
  const text = dayAndTime(date, now, l).replace(" at ", " ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** "4:12" (minutos:segundos, o h:mm:ss pasada la hora). */
export function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor(total / 60) % 60;
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/** "3m 40s", "45s", "1h 5m". */
export function duration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor(total / 60) % 60}m`;
}

/** "$48.20". */
export function money(value: number): string {
  return `$${value.toFixed(2)}`;
}

/** "11.2 GB", "212 GB", "640 MB" (unidades decimales, como Finder). */
export function bytes(value: number): string {
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let amount = value;
  let unit = 0;
  while (amount >= 1000 && unit < units.length - 1) {
    amount /= 1000;
    unit++;
  }
  if (unit === 0) return `${value} bytes`;
  const text = amount < 100 && Math.round(amount) !== amount ? amount.toFixed(1) : amount.toFixed(0);
  return `${text} ${units[unit]}`;
}

/** "Laura Méndez" → "LM"; "lmendez" → "LM"; "ana-pereira" → "AP". */
export function initials(name: string): string {
  const words = name.split(/[ \-_.]+/).filter((w) => w.length > 0);
  if (words.length >= 2) return ([...words[0]!][0]! + [...words[1]!][0]!).toUpperCase();
  return [...name].slice(0, 2).join("").toUpperCase();
}

/** "1 comment" / "4 comments". */
export function count(n: number, singular: string, plural?: string): string {
  return `${n} ${n === 1 ? singular : plural ?? `${singular}s`}`;
}

/** La línea de un `archivo:línea` (`src/a.ts:88` → 88). */
export function lineOf(location: string): number | null {
  const last = location.split(":").pop() ?? "";
  return /^\d+$/.test(last) ? Number(last) : null;
}

/** Una persona para un avatar: nombre visible (o el login), iniciales y color estable por login. */
export function person(login: string, name?: string): Person {
  const shown = name && name.length > 0 ? name : login;
  return { name: shown, login, initials: initials(shown), color: avatarColor(login) };
}

/** Milisegundos de una fecha ISO 8601, o `null`. */
export function parseDate(text: string | undefined): number | null {
  if (!text) return null;
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms;
}
