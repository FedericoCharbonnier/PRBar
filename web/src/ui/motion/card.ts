import { animate, cancelAnimations, reducedMotion } from "./animate";
import { cardScale, clamp, EASE_SPRING, SHEET_MS } from "./math";

// La presentación "tarjeta" de iOS: con una hoja grande abierta, la pantalla de atrás (`.nav-host`) se achica un poco,
// se redondea y queda sobre negro. `progress` sigue el arrastre de la hoja (1 = presentada, 0 = sin hoja).

let presented = 0;
/** env(safe-area-inset-top) medido al presentar (no en cada cuadro del arrastre). */
let top = 0;

function host(): HTMLElement | null {
  return typeof document === "undefined" ? null : (document.querySelector("#app .nav-host") as HTMLElement | null);
}

/** El inset superior real (env(safe-area-inset-top)) en px. */
export function safeTop(): number {
  if (typeof document === "undefined") return 0;
  const probe = document.createElement("div");
  probe.className = "safe-probe";
  document.body.appendChild(probe);
  const value = probe.offsetHeight;
  probe.remove();
  return value;
}

function frame(progress: number): string {
  const el = host();
  const width = el?.clientWidth ?? 0;
  const p = clamp(progress, 0, 1);
  const scale = 1 - (1 - cardScale(width)) * p;
  return `translate3d(0, ${(top + 10) * p}px, 0) scale(${scale})`;
}

export function presentCard(): void {
  presented++;
  const el = host();
  if (!el || presented > 1 || reducedMotion()) return;
  top = safeTop();
  document.documentElement.classList.add("card-presenting");
  el.classList.add("nav-host--card");
  cancelAnimations(el);
  el.style.transform = frame(1);
  void animate(el, [{ transform: frame(0) }, { transform: frame(1) }], { duration: SHEET_MS, easing: EASE_SPRING });
}

export function dismissCard(from = 1): void {
  presented = Math.max(0, presented - 1);
  const el = host();
  if (!el || presented > 0 || !el.classList.contains("nav-host--card")) return;
  cancelAnimations(el);
  el.style.transform = "";
  void animate(el, [{ transform: frame(from) }, { transform: frame(0) }], { duration: 360, easing: EASE_SPRING }).then(() => {
    if (presented > 0) return;
    el.classList.remove("nav-host--card");
    document.documentElement.classList.remove("card-presenting");
  });
}

/** Durante el arrastre de la hoja. */
export function trackCard(progress: number): void {
  const el = host();
  if (!el || !el.classList.contains("nav-host--card")) return;
  cancelAnimations(el);
  el.style.transform = frame(progress);
}
