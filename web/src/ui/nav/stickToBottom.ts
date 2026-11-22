import type { RefObject } from "preact";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { KEYBOARD_EVENT } from "../viewport";

// El chat se lee de abajo para arriba (revisión H2): abre en el último mensaje y, cuando llega uno nuevo o un pedazo de
// la respuesta, baja solo si ya estaba abajo (si el usuario subió a leer algo, no se lo mueve).

/** A menos de esto del fondo cuenta como "abajo". */
export const NEAR_BOTTOM_PX = 80;

export interface ScrollMetrics {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

export function isNearBottom({ scrollTop, scrollHeight, clientHeight }: ScrollMetrics, threshold = NEAR_BOTTOM_PX): boolean {
  return scrollHeight - scrollTop - clientHeight <= threshold;
}

function toBottom(el: HTMLElement): void {
  el.scrollTop = el.scrollHeight;
}

/** Mantiene `scroller` abajo: al montar, cada vez que cambia `content` (si estaba abajo) y cuando se abre o cierra el
 *  teclado. Devuelve `force()` para bajar sí o sí (al mandar un mensaje). */
export function useStickToBottom(scroller: RefObject<HTMLElement> | undefined, content: unknown): () => void {
  const near = useRef(true);
  const force = useRef(false);

  useEffect(() => {
    const el = scroller?.current;
    if (!el) return;
    const onScroll = () => {
      near.current = isNearBottom(el);
    };
    const onKeyboard = () => {
      if (near.current) toBottom(el);
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    addEventListener(KEYBOARD_EVENT, onKeyboard);
    return () => {
      el.removeEventListener("scroll", onScroll);
      removeEventListener(KEYBOARD_EVENT, onKeyboard);
    };
  }, [scroller]);

  // Antes de pintar: el primer cuadro ya muestra el final (sin saltar desde arriba).
  useLayoutEffect(() => {
    const el = scroller?.current;
    if (!el) return;
    if (near.current || force.current) {
      toBottom(el);
      near.current = true;
    }
    force.current = false;
  }, [scroller, content]);

  return () => {
    force.current = true;
    const el = scroller?.current;
    if (el) toBottom(el);
    near.current = true;
  };
}
