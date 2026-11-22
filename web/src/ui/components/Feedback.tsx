import type { ComponentChildren } from "preact";
import { Icon, type IconName } from "./Icon";
import { Button } from "./Button";
import type { BannerVM } from "../screens/types";
import "./components.css";

// Avisos: banner fino (sin red / datos viejos), estado vacío y el código de verificación (SAS).

export function Banner({ banner, onAction }: { banner: BannerVM; onAction?: (() => void) | undefined }) {
  return (
    <div class={`banner banner--${banner.tone}`} role="status">
      {banner.icon && <Icon name={banner.icon} size={17} />}
      <span class="banner__text">{banner.text}</span>
      {banner.actionLabel && (
        <button type="button" class="banner__action" onClick={onAction}>
          {banner.actionLabel}
        </button>
      )}
    </div>
  );
}

export function EmptyState({ icon, title, message, action }: {
  icon: IconName; title: string; message?: string | undefined;
  action?: { label: string; icon?: IconName | undefined; onClick: () => void } | undefined;
}) {
  return (
    <div class="empty">
      <Icon name={icon} size={44} class="empty__icon" />
      <h2 class="empty__title">{title}</h2>
      {message && <p class="empty__message">{message}</p>}
      {action && (
        <Button variant="tinted" size="md" icon={action.icon} onClick={action.onClick}>
          {action.label}
        </Button>
      )}
    </div>
  );
}

/** Seis dígitos en fichas 44×58 con separación extra después del tercero. */
export function SASCode({ code }: { code: string }) {
  const digits = code.replace(/\D/g, "").split("");
  return (
    <div class="sas" role="img" aria-label={`Verification code ${digits.join(" ")}`}>
      {digits.map((d, i) => (
        <span key={i} class={i === 3 ? "sas__digit sas__digit--gap" : "sas__digit"} aria-hidden="true">
          {d}
        </span>
      ))}
    </div>
  );
}

/** Barra de acciones fija abajo, sobre un degradado del fondo. */
export function BottomBar({ children, plain }: { children: ComponentChildren; plain?: boolean }) {
  return (
    <div class={plain ? "bottom-bar bottom-bar--plain" : "bottom-bar"}>
      <div class="bottom-bar__inner">{children}</div>
    </div>
  );
}
