import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./Icon";
import type { Person, Severity } from "../screens/types";
import "./components.css";

// Piezas chicas reutilizadas por todas las pantallas.

/** Paleta de avatares: cada persona tiene un color fijo derivado de su login (como en la app nativa). */
const AVATAR_COLORS = ["#C42B1F", "#12793A", "#2D4EFF", "#A65300", "#6B2FB3", "#1F5FBF", "#B0306A", "#0F7A80"];

export function avatarColor(login: string): string {
  let h = 0;
  for (let i = 0; i < login.length; i++) h = (h * 31 + login.charCodeAt(i)) >>> 0;
  return AVATAR_COLORS[h % AVATAR_COLORS.length] ?? "#2D4EFF";
}

export function Avatar({ person, size = 34, disabled }: { person: Person; size?: number; disabled?: boolean | undefined }) {
  return (
    <span
      class={disabled ? "avatar avatar--disabled" : "avatar"}
      style={{ width: `${size}px`, height: `${size}px`, fontSize: `${Math.round(size * 0.4)}px`, background: disabled ? undefined : person.color }}
      aria-hidden="true"
    >
      {person.initials}
    </span>
  );
}

export function StatusDot({ online, size = 7 }: { online: boolean; size?: number }) {
  return (
    <span
      class={online ? "status-dot status-dot--on" : "status-dot"}
      style={{ width: `${size}px`, height: `${size}px` }}
      aria-hidden="true"
    />
  );
}

/** Insignia roja con número (pestaña To Review). */
export function Badge({ count }: { count: number }) {
  if (count <= 0) return null;
  return <span class="badge">{count > 99 ? "99+" : count}</span>;
}

export function Spinner({ size = 16, class: cls }: { size?: number; class?: string }) {
  return (
    <svg class={cls ? `spinner ${cls}` : "spinner"} width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 3a9 9 0 1 1-8.6 6.3" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" />
    </svg>
  );
}

/** Chip mono de rama (`fix/session-expiry`). */
export function Chip({ children }: { children: ComponentChildren }) {
  return <span class="chip">{children}</span>;
}

const SEVERITY_LABEL: Record<Severity, string> = { high: "High", medium: "Medium", low: "Low" };

export function SeverityPill({ severity }: { severity: Severity }) {
  return (
    <span class={`severity severity--${severity}`}>
      <span class="severity__dot" aria-hidden="true" />
      {SEVERITY_LABEL[severity]}
    </span>
  );
}

/** Cuadro azul de la app con el glifo de PRBar (Welcome 100, Settings 40). */
export function AppTile({ size = 100, icon = "prbar", glow }: { size?: number; icon?: IconName; glow?: boolean }) {
  return (
    <span
      class={glow ? "app-tile app-tile--glow" : "app-tile"}
      style={{ width: `${size}px`, height: `${size}px`, borderRadius: `${Math.round(size * 0.27)}px` }}
      aria-hidden="true"
    >
      <Icon name={icon} size={Math.round(size * 0.56)} />
    </span>
  );
}

/** Círculo grande de resultado (checkmark verde, merge azul, Mac gris). */
export function HeroCircle({ icon, tone, size = 88, iconSize }: {
  icon: IconName; tone: "green" | "accent" | "fill"; size?: number; iconSize?: number;
}) {
  return (
    <span class={`hero-circle hero-circle--${tone}`} style={{ width: `${size}px`, height: `${size}px` }} aria-hidden="true">
      <Icon name={icon} size={iconSize ?? Math.round(size * 0.5)} />
    </span>
  );
}

/** Conteo de líneas `+46 −12` en mono, verde y rojo. */
export function DiffCount({ additions, deletions, mono = true }: { additions: number; deletions: number; mono?: boolean }) {
  return (
    <span class={mono ? "diffcount diffcount--mono" : "diffcount"}>
      <span class="diffcount__add">+{additions}</span>
      <span class="diffcount__del">−{deletions}</span>
    </span>
  );
}

/** Fondo de pantalla: agrupado (`bg`) o liso (`bg2`, chat y emparejamiento). */
export function Screen({ children, variant = "grouped", class: cls, label }: {
  children: ComponentChildren; variant?: "grouped" | "plain" | "dark"; class?: string; label?: string;
}) {
  return (
    <main class={`screen screen--${variant}${cls ? ` ${cls}` : ""}`} aria-label={label}>
      {children}
    </main>
  );
}
