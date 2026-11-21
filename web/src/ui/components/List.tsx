import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./Icon";
import { Toggle } from "./Toggle";
import "./components.css";

// Listas agrupadas: tarjeta bg2 redondeada, filas con separador de 0.5 pt y secciones plegables.

export function Card({ children, class: cls, inset }: { children: ComponentChildren; class?: string; inset?: boolean }) {
  return <div class={`card${inset ? " card--inset" : ""}${cls ? ` ${cls}` : ""}`}>{children}</div>;
}

/** Encabezado de sección plegable: título 17 semibold + conteo + chevron. Todo el encabezado alterna. */
export function SectionHeader({ title, count, collapsed, dimmed, onToggle }: {
  title: string; count?: number | undefined; collapsed?: boolean | undefined; dimmed?: boolean | undefined;
  onToggle?: (() => void) | undefined;
}) {
  const content = (
    <>
      <span class="section-header__title">{title}</span>
      {count != null && <span class="section-header__count">{count}</span>}
    </>
  );
  if (!onToggle) return <h2 class={`section-header${dimmed ? " section-header--dim" : ""}`}>{content}</h2>;
  return (
    <h2 class={`section-header${dimmed ? " section-header--dim" : ""}`}>
      <button
        type="button"
        class="section-header__btn"
        aria-expanded={!collapsed}
        aria-label={`${title}, ${count ?? 0}, ${collapsed ? "collapsed" : "expanded"}`}
        onClick={onToggle}
      >
        {content}
        <Icon name={collapsed ? "chevron.right" : "chevron.down"} size={collapsed ? 16 : 17} class="section-header__chevron" />
      </button>
    </h2>
  );
}

export function Section({ title, count, collapsed, dimmed, onToggle, children }: {
  title: string; count?: number | undefined; collapsed?: boolean | undefined; dimmed?: boolean | undefined;
  onToggle?: (() => void) | undefined; children: ComponentChildren;
}) {
  return (
    <section class="section">
      <SectionHeader title={title} count={count} collapsed={collapsed} dimmed={dimmed} onToggle={onToggle} />
      {!collapsed && <Card>{children}</Card>}
    </section>
  );
}

/** Título de bloque de contenido ("Findings", "Feedback") con texto secundario a la derecha. */
export function BlockTitle({ title, trailing }: { title: string; trailing?: string | undefined }) {
  return (
    <div class="block-title">
      <h2>{title}</h2>
      {trailing && <span>{trailing}</span>}
    </div>
  );
}

/** Rótulo en mayúsculas sobre una tarjeta ("NOTIFICATIONS", "MERGE METHOD"). */
export function ListCaption({ children }: { children: ComponentChildren }) {
  return <h3 class="list-caption">{children}</h3>;
}

export interface ListRowProps {
  label: ComponentChildren;
  value?: ComponentChildren;
  valueTone?: "green" | "orange" | "red" | "fg2" | undefined;
  icon?: IconName | undefined;
  leading?: ComponentChildren;
  chevron?: boolean | undefined;
  destructive?: boolean | undefined;
  onClick?: (() => void) | undefined;
}

/** Fila de lista (46 pt): ícono/avatar, etiqueta, valor a la derecha y chevron opcional. */
export function ListRow({ label, value, valueTone = "fg2", icon, leading, chevron, destructive, onClick }: ListRowProps) {
  const inner = (
    <>
      {(icon || leading) && <span class="list-row__lead">{leading ?? (icon && <Icon name={icon} size={24} />)}</span>}
      <span class={destructive ? "list-row__label list-row__label--red" : "list-row__label"}>{label}</span>
      {value != null && <span class={`list-row__value list-row__value--${valueTone}`}>{value}</span>}
      {chevron && <Icon name="chevron.right" size={15} class="list-row__chevron" />}
    </>
  );
  const cls = `list-row${icon || leading ? " list-row--lead" : ""}`;
  return onClick ? (
    <button type="button" class={`${cls} list-row--btn`} onClick={onClick}>
      {inner}
    </button>
  ) : (
    <div class={cls}>{inner}</div>
  );
}

/** Fila con interruptor del sistema. */
export function ToggleRow({ label, on, disabled, onChange }: {
  label: string; on: boolean; disabled?: boolean | undefined; onChange: (on: boolean) => void;
}) {
  return (
    <label class="list-row list-row--toggle">
      <span class="list-row__label">{label}</span>
      <Toggle on={on} disabled={disabled} label={label} onChange={onChange} />
    </label>
  );
}
