import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./Icon";
import { Spinner } from "./basics";
import type { PRAction } from "../screens/types";
import "./components.css";

// Botones del sistema: lleno (accent), teñido (accentbg), liso (solo texto), destructivo y vidrio (Liquid Glass).

export type ButtonVariant = "filled" | "tinted" | "plain" | "destructive" | "destructive-tinted" | "glass";
export type ButtonSize = "sm" | "md" | "lg" | "xl";

export interface ButtonProps {
  children?: ComponentChildren;
  variant?: ButtonVariant;
  /** sm 32, md 44, lg 54, xl 56. */
  size?: ButtonSize;
  icon?: IconName | undefined;
  /** Ícono después del texto (`arrow.up.right` en "View on GitHub"). */
  trailingIcon?: IconName | undefined;
  block?: boolean;
  disabled?: boolean | undefined;
  busy?: boolean | undefined;
  label?: string | undefined;
  class?: string | undefined;
  type?: "button" | "submit";
  onClick?: (() => void) | undefined;
}

export function Button({
  children, variant = "filled", size = "lg", icon, trailingIcon, block, disabled, busy, label, class: cls, type = "button", onClick,
}: ButtonProps) {
  const classes = ["btn", `btn--${variant}`, `btn--${size}`];
  if (block) classes.push("btn--block");
  if (cls) classes.push(cls);
  return (
    <button
      type={type}
      class={classes.join(" ")}
      disabled={disabled || busy}
      aria-label={label}
      aria-busy={busy ? "true" : undefined}
      onClick={onClick}
    >
      {busy ? <Spinner size={18} /> : icon ? <Icon name={icon} size={size === "sm" ? 15 : size === "md" ? 18 : 21} /> : null}
      {children != null && <span class="btn__label">{children}</span>}
      {trailingIcon && <Icon name={trailingIcon} size={22} class="btn__trailing" />}
    </button>
  );
}

/** Botón circular de vidrio de 44 pt de la barra de navegación. */
export function GlassButton({ icon, label, onClick, iconSize = 22, disabled }: {
  icon: IconName; label: string; onClick?: (() => void) | undefined; iconSize?: number | undefined; disabled?: boolean | undefined;
}) {
  return (
    <button type="button" class="glass-btn" aria-label={label} title={label} disabled={disabled} onClick={onClick}>
      <Icon name={icon} size={iconSize} />
    </button>
  );
}

/** Grupo de botones de vidrio pegados (la barra de Review: chat + más). */
export function GlassGroup({ children }: { children: ComponentChildren }) {
  return <div class="glass-group">{children}</div>;
}

const ACTION_CLASS: Record<PRAction["kind"], string> = {
  review: "capsule--tinted",
  respond: "capsule--tinted",
  reviewing: "capsule--violet",
  comments: "capsule--green",
  merge: "capsule--filled",
  fixci: "capsule--red",
};

/** Cápsula de acción de la fila de PR (30 pt dibujada, 44 pt de toque). */
export function ActionCapsule({ action, disabled, onClick }: {
  action: PRAction; disabled?: boolean | undefined; onClick?: (() => void) | undefined;
}) {
  const cls = disabled ? "capsule capsule--disabled" : `capsule ${ACTION_CLASS[action.kind]}`;
  return (
    <button
      key={action.kind}
      type="button"
      class={cls}
      disabled={disabled}
      aria-label={disabled ? `${action.label}, unavailable` : action.label}
      onClick={(e) => {
        e.stopPropagation();
        onClick?.();
      }}
    >
      {action.kind === "reviewing" && !disabled && <Spinner size={16} />}
      {action.kind === "comments" && <Icon name="checkmark.circle.fill" size={17} class="capsule__check" />}
      <span>{action.label}</span>
    </button>
  );
}
