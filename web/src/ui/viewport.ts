// El teclado de iOS (revisión M3): Safari no achica la ventana cuando aparece el teclado; corre la vista entera (la app
// es fija) para mostrar el campo y, al cerrarlo, a veces la deja corrida. Acá se sigue `visualViewport`: `--kb` en
// `<html>` es lo que el teclado tapa abajo (el compositor del chat, las hojas y el scroll de cada pantalla se apoyan
// arriba de eso, ver app.css) y la vista se devuelve a su lugar (`scrollTo(0, 0)`) mientras se escribe y al terminar.

export interface ViewportMetrics {
  /** `window.innerHeight` (la ventana de layout). */
  innerHeight: number;
  /** `visualViewport.height` (lo que se ve: sin el teclado). */
  height: number;
  /** `visualViewport.offsetTop` (cuánto corrió Safari la vista hacia arriba). */
  offsetTop: number;
  /** `visualViewport.scale`: con zoom de pellizco la vista es más chica sin que haya teclado. */
  scale?: number;
}

/** Menos que esto no es un teclado (redondeos, la barra de Safari). */
const MIN_KEYBOARD = 80;

/** Cuánto tapa el teclado del borde de abajo de la ventana (px, 0 sin teclado). */
export function keyboardInset({ innerHeight, height, offsetTop, scale = 1 }: ViewportMetrics): number {
  if (Math.abs(scale - 1) > 0.01) return 0;
  const inset = Math.round(innerHeight - height - offsetTop);
  return inset >= MIN_KEYBOARD ? inset : 0;
}

/** Si un campo (por su rectángulo) queda tapado por el teclado: su borde de abajo pasa lo que se ve. */
export function hiddenByKeyboard(rect: { bottom: number }, innerHeight: number, inset: number, margin = 8): boolean {
  return inset > 0 && rect.bottom > innerHeight - inset - margin;
}

function editable(element: Element | null): element is HTMLElement {
  if (!element) return false;
  const tag = element.tagName;
  if (tag === "TEXTAREA") return true;
  if (tag === "INPUT") return !["button", "checkbox", "radio", "submit", "reset", "range"].includes((element as HTMLInputElement).type);
  return (element as HTMLElement).isContentEditable;
}

/** Evento en `window` cuando cambia el teclado (el chat se queda abajo si ya estaba abajo). */
export const KEYBOARD_EVENT = "prbar:keyboard";

/** Empieza a seguir el teclado. Devuelve cómo parar. */
export function installKeyboardTracking(win: Window = window): () => void {
  const vv = win.visualViewport;
  if (!vv) return () => {};
  const root = win.document.documentElement;
  let current = 0;
  let pending: ReturnType<typeof setTimeout> | null = null;

  const update = () => {
    const focused = win.document.activeElement;
    // Con un campo abierto, Safari corre toda la app fija hacia arriba (la barra de navegación sale de la pantalla).
    // Como lo de abajo ya se apoya arriba del teclado, se devuelve la vista a su lugar.
    const zoomed = Math.abs(vv.scale - 1) > 0.01;
    if (vv.offsetTop > 0 && !zoomed && editable(focused)) win.scrollTo(0, 0);
    const inset = keyboardInset({ innerHeight: win.innerHeight, height: vv.height, offsetTop: Math.max(0, vv.offsetTop),
                                  scale: vv.scale });
    if (inset === current) return;
    current = inset;
    root.style.setProperty("--kb", `${inset}px`);
    root.classList.toggle("kb-open", inset > 0);
    win.dispatchEvent(new Event(KEYBOARD_EVENT));
    // Un campo dentro del scroll de la pantalla (no fijo) que quedó debajo del teclado: se trae a la vista.
    if (editable(focused)) {
      win.requestAnimationFrame(() => {
        if (hiddenByKeyboard(focused.getBoundingClientRect(), win.innerHeight, current)) {
          focused.scrollIntoView({ block: "nearest" });
        }
      });
    }
  };

  // Al salir de un campo (y no entrar en otro) iOS puede dejar la vista corrida y un hueco abajo: se acomoda.
  const focusOut = () => {
    if (pending !== null) clearTimeout(pending);
    pending = setTimeout(() => {
      pending = null;
      if (editable(win.document.activeElement)) return;
      win.scrollTo(0, 0);
      update();
    }, 100);
  };

  vv.addEventListener("resize", update);
  vv.addEventListener("scroll", update);
  win.addEventListener("focusout", focusOut);
  return () => {
    vv.removeEventListener("resize", update);
    vv.removeEventListener("scroll", update);
    win.removeEventListener("focusout", focusOut);
    if (pending !== null) clearTimeout(pending);
  };
}
