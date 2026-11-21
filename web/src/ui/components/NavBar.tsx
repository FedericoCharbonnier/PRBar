import type { ComponentChildren } from "preact";
import { GlassButton } from "./Button";
import { Icon, type IconName } from "./Icon";
import { StatusDot } from "./basics";
import type { MacInfo } from "../screens/types";
import "./components.css";

// Barra de navegación: botones circulares de vidrio a los lados y título en línea opcional al centro.

export interface NavAction {
  icon: IconName;
  label: string;
  onClick?: (() => void) | undefined;
  iconSize?: number | undefined;
}

// Tamaño del glifo por símbolo (los SF Symbols tienen anchos ópticos distintos).
const ICON_SIZE: Partial<Record<IconName, number>> = { "bubble.left.and.bubble.right": 27, ellipsis: 22, xmark: 20 };

export interface NavBarProps {
  leading?: NavAction | undefined;
  /** Contenido a la izquierda en lugar del botón (la píldora de la Mac). */
  leadingContent?: ComponentChildren;
  title?: string | undefined;
  subtitle?: string | undefined;
  titleIcon?: IconName | undefined;
  trailing?: NavAction[] | undefined;
}

export function NavBar({ leading, leadingContent, title, subtitle, titleIcon, trailing = [] }: NavBarProps) {
  return (
    <header class="navbar">
      <div class="navbar__side">
        {leadingContent ?? (leading && <GlassButton icon={leading.icon} label={leading.label} onClick={leading.onClick} iconSize={leading.iconSize ?? ICON_SIZE[leading.icon]} />)}
      </div>
      {title && (
        <div class={subtitle ? "navbar__title navbar__title--sub" : "navbar__title"}>
          <h1>
            {titleIcon && <Icon name={titleIcon} size={19} class="navbar__title-icon" />}
            {title}
          </h1>
          {subtitle && <p>{subtitle}</p>}
        </div>
      )}
      <div class="navbar__side navbar__side--end">
        {trailing.map((a) => (
          <GlassButton key={a.label} icon={a.icon} label={a.label} onClick={a.onClick} iconSize={a.iconSize ?? ICON_SIZE[a.icon]} />
        ))}
      </div>
    </header>
  );
}

/** Título grande (34 pt en el diseño) de las pantallas de pestaña. */
export function LargeTitle({ children }: { children: ComponentChildren }) {
  return <h1 class="large-title">{children}</h1>;
}

/** Píldora de vidrio con la Mac: círculo con `laptopcomputer`, nombre y estado. */
export function MacPill({ mac, onClick }: { mac: MacInfo; onClick?: (() => void) | undefined }) {
  const state = mac.online ? "connected" : "offline";
  return (
    <button
      type="button"
      class="mac-pill"
      aria-label={`${mac.name}, ${state}, ${mac.detail.split(" · ").slice(1).join(" ")}`}
      onClick={onClick}
    >
      <span class="mac-pill__icon">
        <Icon name="laptopcomputer" size={22} />
      </span>
      <span class="mac-pill__text">
        <span class="mac-pill__name">{mac.name}</span>
        <span class="mac-pill__detail">
          <StatusDot online={mac.online} />
          {mac.detail}
        </span>
      </span>
    </button>
  );
}
