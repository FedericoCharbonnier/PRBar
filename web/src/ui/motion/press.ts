// Respuesta al toque como en UIKit: en iOS `:active` casi no se ve (Safari lo aplica tarde o nunca), así que la clase
// `pressed` se pone a mano. Como UIScrollView (`delaysContentTouches`), se espera un instante antes de resaltar para
// que empezar a desplazar no ilumine la fila; si el dedo se levanta antes, el resaltado igual parpadea.

const PRESSABLE = "button:not(:disabled), a[href], [role=button], label.list-row--toggle, .pressable";
const DELAY_MS = 70;
const FLASH_MS = 110;
const SLOP = 10;

let installed = false;

export function installPressFeedback(doc: Document = document): void {
  if (installed || typeof doc === "undefined") return;
  installed = true;
  // Un listener de touchstart (aunque vacío) hace que Safari aplique `:active`.
  doc.addEventListener("touchstart", () => {}, { passive: true });

  let target: Element | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let start = { x: 0, y: 0 };
  let shown = false;

  const clear = (flash: boolean) => {
    if (timer) clearTimeout(timer);
    timer = null;
    const el = target;
    target = null;
    if (!el) return;
    if (flash && !shown) {
      el.classList.add("pressed");
      setTimeout(() => el.classList.remove("pressed"), FLASH_MS);
    } else {
      el.classList.remove("pressed");
    }
    shown = false;
  };

  doc.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 && e.pointerType === "mouse") return;
    clear(false);
    const el = (e.target as Element | null)?.closest?.(PRESSABLE) ?? null;
    if (!el || el.closest("[inert]")) return;
    target = el;
    start = { x: e.clientX, y: e.clientY };
    timer = setTimeout(() => {
      timer = null;
      if (target) {
        target.classList.add("pressed");
        shown = true;
      }
    }, e.pointerType === "touch" ? DELAY_MS : 0);
  }, { passive: true, capture: true });

  doc.addEventListener("pointermove", (e) => {
    if (!target) return;
    if (Math.hypot(e.clientX - start.x, e.clientY - start.y) > SLOP) clear(false);
  }, { passive: true, capture: true });

  doc.addEventListener("pointerup", () => clear(true), { passive: true, capture: true });
  doc.addEventListener("pointercancel", () => clear(false), { passive: true, capture: true });
  // Empezó a desplazarse una lista: no es un toque.
  doc.addEventListener("scroll", () => clear(false), { passive: true, capture: true });
}
