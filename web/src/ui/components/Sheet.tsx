import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./Icon";
import "./components.css";

// Hoja inferior con agarradera, menú de acciones (estilo menú del sistema) y el HUD de Face ID.

export function Sheet({ children, open = true, grabber = true, detent = "large", label, onDismiss }: {
  children: ComponentChildren;
  open?: boolean;
  grabber?: boolean;
  /** large = casi toda la pantalla; medium = la mitad; full = toda (edición). */
  detent?: "large" | "medium" | "full";
  label?: string | undefined;
  onDismiss?: (() => void) | undefined;
}) {
  if (!open) return null;
  return (
    <div class={`sheet-layer sheet-layer--${detent}`}>
      {detent !== "full" && <button type="button" class="sheet-scrim" aria-label="Dismiss" onClick={onDismiss} />}
      <div class={`sheet sheet--${detent}`} role="dialog" aria-modal="true" aria-label={label}>
        {grabber && <span class="sheet__grabber" aria-hidden="true" />}
        {children}
      </div>
    </div>
  );
}

export interface MenuItem<T extends string = string> {
  id: T;
  label: string;
  icon?: IconName | undefined;
  tone?: "green" | "orange" | "red" | undefined;
  checked?: boolean | undefined;
  destructive?: boolean | undefined;
}

/** Menú contextual del sistema: lista con check en la opción elegida, anclado arriba o abajo. */
export function ActionMenu<T extends string>({ items, label, anchor = "bottom-start", onSelect, onDismiss }: {
  items: MenuItem<T>[];
  label: string;
  anchor?: "bottom-start" | "top-end";
  onSelect: (id: T) => void;
  onDismiss: () => void;
}) {
  return (
    <div class="menu-layer">
      <button type="button" class="menu-scrim" aria-label="Dismiss" onClick={onDismiss} />
      <div class={`menu menu--${anchor}`} role="menu" aria-label={label}>
        {items.map((it) => (
          <button
            key={it.id}
            type="button"
            role="menuitemradio"
            aria-checked={!!it.checked}
            class={`menu__item${it.destructive ? " menu__item--red" : ""}`}
            onClick={() => onSelect(it.id)}
          >
            <span class="menu__check">{it.checked && <Icon name="checkmark" size={16} />}</span>
            <span class="menu__label">{it.label}</span>
            {it.icon && <Icon name={it.icon} size={20} class={it.tone ? `menu__icon tone-${it.tone}` : "menu__icon"} />}
          </button>
        ))}
      </div>
    </div>
  );
}

/** HUD de Face ID mientras el sistema pide la biometría (el aviso real es del sistema). */
export function FaceIdHud({ text = "Waiting for Face ID…" }: { text?: string }) {
  return (
    <div class="hud-layer" role="status" aria-live="polite">
      <div class="hud">
        <Icon name="faceid" size={66} />
        <span>{text}</span>
      </div>
    </div>
  );
}
