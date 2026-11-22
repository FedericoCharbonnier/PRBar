import type { ComponentChildren } from "preact";
import { createPortal } from "preact/compat";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { animate, cancelAnimations, ghost, reducedMotion } from "../motion/animate";
import { dismissCard, presentCard, trackCard } from "../motion/card";
import {
  addSample, clamp, EASE_SPRING, gestureAxis, rubberBand, settleDuration, SHEET_MS, sheetOffset, shouldDismissSheet, velocityOf,
  type Sample,
} from "../motion/math";
import { usePage } from "../nav/context";
import { Icon, type IconName } from "./Icon";
import "./components.css";

// Hoja inferior con agarradera, menú de acciones (estilo menú del sistema) y el HUD de Face ID.

/** Contenedor de las hojas, fuera de las pantallas (así la de atrás puede achicarse sin achicar la hoja). */
function overlayRoot(): HTMLElement {
  let root = document.getElementById("overlay-root");
  if (!root) {
    root = document.createElement("div");
    root.id = "overlay-root";
    document.body.appendChild(root);
  }
  return root;
}

export function Sheet(props: {
  children: ComponentChildren;
  open?: boolean;
  grabber?: boolean;
  /** large = casi toda la pantalla (la de atrás queda como tarjeta); medium = la mitad; full = toda. */
  detent?: "large" | "medium" | "full";
  label?: string | undefined;
  onDismiss?: (() => void) | undefined;
}) {
  // Una hoja de una pantalla que quedó tapada (p. ej. una notificación abrió otro PR con la hoja abierta) no se queda
  // encima de la nueva: se cierra y vuelve a aparecer al volver (el borrador vive en el modelo).
  const page = usePage();
  if (props.open === false || (page && !page.visible)) return null;
  return createPortal(<SheetLayer {...props} />, overlayRoot());
}

/** Con una hoja abierta, lo de atrás queda inerte (VoiceOver no entra ahí) y el foco va a la hoja; al cerrarla vuelve
 *  a donde estaba. Varias hojas a la vez cuentan una sola vez. */
let modalCount = 0;
let inerted: Element[] = [];

function enterModal(sheet: HTMLElement | null): () => void {
  const previous = document.activeElement as HTMLElement | null;
  if (modalCount++ === 0) {
    inerted = [...document.querySelectorAll("#app > :not(.app-alerts)")];
    for (const el of inerted) el.setAttribute("inert", "");
  }
  sheet?.focus({ preventScroll: true });
  return () => {
    if (--modalCount === 0) {
      for (const el of inerted) el.removeAttribute("inert");
      inerted = [];
    }
    if (previous?.isConnected && !previous.closest("[inert]")) previous.focus({ preventScroll: true });
  };
}

/** Una hoja como UISheetPresentationController: sube desde abajo sobre un fondo oscurecido, se arrastra hacia abajo
 *  para cerrarla (con rebote hacia arriba y según la velocidad al soltar) y se cierra tocando el fondo. */
function SheetLayer({ children, grabber = true, detent = "large", label, onDismiss }: Parameters<typeof Sheet>[0]) {
  const layer = useRef<HTMLDivElement>(null);
  const sheet = useRef<HTMLDivElement>(null);
  const live = useRef({ onDismiss, dragged: false, progress: 1 });
  live.current.onDismiss = onDismiss;
  const card = detent === "large";

  useLayoutEffect(() => {
    const el = sheet.current;
    const scrim = layer.current?.querySelector(".sheet-scrim");
    const reduce = reducedMotion();
    if (reduce) {
      void animate(layer.current, [{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
    } else {
      void animate(el, [{ transform: "translate3d(0, 100%, 0)" }, { transform: "translate3d(0, 0, 0)" }], { duration: SHEET_MS, easing: EASE_SPRING });
      void animate(scrim, [{ opacity: 0 }, { opacity: 1 }], { duration: SHEET_MS, easing: "ease-out" });
    }
    if (card) presentCard();
    const leaveModal = enterModal(el);
    const root = layer.current;
    return () => {
      leaveModal();
      // Cerrada arrastrando: la pantalla de atrás sigue desde donde la dejó el arrastre (sin saltar a presentada).
      if (card) dismissCard(live.current.dragged ? live.current.progress : 1);
      if (live.current.dragged) return;
      ghost(root, (copy) => {
        if (reduce) return [{ opacity: 1 }, { opacity: 0 }];
        void animate(copy.querySelector(".sheet"), [{ transform: "translate3d(0, 0, 0)" }, { transform: "translate3d(0, 100%, 0)" }], { duration: 340, easing: "cubic-bezier(0.4, 0, 0.8, 0.6)", hold: true });
        void animate(copy.querySelector(".sheet-scrim"), [{ opacity: 1 }, { opacity: 0 }], { duration: 340, hold: true });
        return [{ opacity: 1 }, { opacity: 1 }];
      }, { duration: 340 });
    };
  }, []);

  // ---------- Arrastrar hacia abajo ----------
  useEffect(() => {
    const el = sheet.current;
    const scrim = layer.current?.querySelector(".sheet-scrim") as HTMLElement | null;
    if (!el) return;
    let drag: { id: number; x0: number; y0: number; samples: Sample[]; active: boolean; height: number } | null = null;
    const offsetFor = (dy: number, height: number) => (live.current.onDismiss ? sheetOffset(dy, height) : rubberBand(dy, height));
    const down = (e: PointerEvent) => {
      if (drag || !e.isPrimary || (e.target as Element).closest("textarea, input, select, .code-block, .diff__scroll")) return;
      drag = { id: e.pointerId, x0: e.clientX, y0: e.clientY, samples: [{ t: e.timeStamp, v: 0 }], active: false, height: el.offsetHeight };
    };
    const move = (e: PointerEvent) => {
      if (!drag || e.pointerId !== drag.id) return;
      const dy = e.clientY - drag.y0;
      if (!drag.active) {
        const axis = gestureAxis(e.clientX - drag.x0, dy, 6);
        if (!axis) return;
        if (axis === "x") {
          drag = null;
          return;
        }
        drag.active = true;
        cancelAnimations(el);
        el.style.willChange = "transform";
        try {
          el.setPointerCapture(e.pointerId);
        } catch {
          // Eventos sintéticos.
        }
      }
      drag.samples = addSample(drag.samples, e.timeStamp, dy);
      const offset = offsetFor(dy, drag.height);
      el.style.transform = `translate3d(0, ${offset}px, 0)`;
      const progress = 1 - clamp(offset / drag.height, 0, 1);
      if (scrim) scrim.style.opacity = String(progress);
      if (card) trackCard(progress);
    };
    const up = (e: PointerEvent) => {
      if (!drag || e.pointerId !== drag.id) return;
      const d = drag;
      drag = null;
      if (!d.active) return;
      // Lo que se arrastró no es un toque: el click que sigue no cuenta.
      const swallow = (c: Event) => {
        c.stopPropagation();
        c.preventDefault();
      };
      addEventListener("click", swallow, { capture: true, once: true });
      setTimeout(() => removeEventListener("click", swallow, { capture: true }), 0);
      const dy = e.clientY - d.y0;
      const velocity = velocityOf(d.samples);
      const offset = offsetFor(dy, d.height);
      el.style.transform = "";
      el.style.willChange = "";
      if (scrim) scrim.style.opacity = "";
      const dismiss = live.current.onDismiss;
      if (dismiss && e.type !== "pointercancel" && shouldDismissSheet(dy, velocity, d.height)) {
        live.current.dragged = true;
        const duration = settleDuration(d.height - offset, velocity, 160, 340);
        const progress = 1 - clamp(offset / d.height, 0, 1);
        void animate(el, [{ transform: `translate3d(0, ${offset}px, 0)` }, { transform: `translate3d(0, ${d.height + 40}px, 0)` }], { duration, easing: "cubic-bezier(0.2, 0.8, 0.3, 1)", hold: true });
        void animate(scrim, [{ opacity: progress }, { opacity: 0 }], { duration, hold: true });
        if (card) trackCard(progress);
        live.current.progress = progress;
        setTimeout(dismiss, duration * 0.6);
        return;
      }
      void animate(el, [{ transform: `translate3d(0, ${offset}px, 0)` }, { transform: "translate3d(0, 0, 0)" }], { duration: 380, easing: EASE_SPRING });
      void animate(scrim, [{ opacity: 1 - clamp(offset / d.height, 0, 1) }, { opacity: 1 }], { duration: 380 });
      if (card) trackCard(1);
    };
    el.addEventListener("pointerdown", down);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
    return () => {
      el.removeEventListener("pointerdown", down);
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
    };
  }, []);

  return (
    <div ref={layer} class={`sheet-layer sheet-layer--${detent}`}>
      {detent !== "full" && <button type="button" class="sheet-scrim" aria-label="Dismiss" onClick={onDismiss} />}
      <div ref={sheet} class={`sheet sheet--${detent}`} role="dialog" aria-modal="true" aria-label={label} tabIndex={-1}>
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
  const menu = useRef<HTMLDivElement>(null);
  // Como un menú contextual de iOS: crece desde el botón que lo abrió (la esquina anclada) y se desvanece al cerrar.
  useLayoutEffect(() => {
    const el = menu.current;
    const reduce = reducedMotion();
    void animate(el, reduce
      ? [{ opacity: 0 }, { opacity: 1 }]
      : [{ opacity: 0, transform: "scale(0.35)" }, { opacity: 1, transform: "scale(1)" }], { duration: reduce ? 180 : 420, easing: "cubic-bezier(0.2, 1.15, 0.4, 1)" });
    return () => ghost(el, () => (reduce
      ? [{ opacity: 1 }, { opacity: 0 }]
      : [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.7)" }]), { duration: 200, easing: "ease-in" });
  }, []);
  return (
    <div class="menu-layer">
      <button type="button" class="menu-scrim" aria-label="Dismiss" onClick={onDismiss} />
      <div ref={menu} class={`menu menu--${anchor}`} role="menu" aria-label={label}>
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
