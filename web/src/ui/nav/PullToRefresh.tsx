import { useEffect, useRef } from "preact/hooks";
import { animate, reducedMotion } from "../motion/animate";
import { pullOffset, pullProgress, REFRESH_HOLD, REFRESH_THRESHOLD, spokesFor } from "../motion/math";
import { usePage } from "./context";

// "Tirar para actualizar" como UIRefreshControl: desde arriba de todo el contenido baja con resistencia, el indicador
// de actividad (8 rayos) se va completando y, pasado el umbral, al soltar queda girando hasta que termina `refreshing`.
// Va justo antes de `.screen` (la pantalla que baja; su barra de arriba queda quieta).

const MIN_SPIN_MS = 650;

export function PullToRefresh({ refreshing, onRefresh }: { refreshing: boolean; onRefresh: () => void }) {
  const page = usePage();
  const indicator = useRef<HTMLDivElement>(null);
  const live = useRef({ refreshing, onRefresh, holding: false, since: 0 });
  live.current.refreshing = refreshing;
  live.current.onRefresh = onRefresh;

  const screenOf = () => (indicator.current?.nextElementSibling as HTMLElement | null) ?? null;

  const setOffset = (y: number, settle: boolean) => {
    const screen = screenOf();
    if (!screen) return;
    screen.classList.toggle("screen--ptr-settle", settle);
    screen.classList.toggle("screen--ptr", y > 0);
    screen.style.setProperty("--ptr-y", `${y}px`);
  };

  const setSpokes = (progress: number, spinning: boolean) => {
    const el = indicator.current;
    if (!el) return;
    const n = spokesFor(progress);
    el.querySelectorAll(".ptr__spoke").forEach((s, i) => s.classList.toggle("ptr__spoke--on", spinning || i < n));
    el.classList.toggle("ptr--spinning", spinning);
    el.style.opacity = String(spinning ? 1 : Math.min(1, progress * 1.4));
  };

  const finish = () => {
    const state = live.current;
    if (!state.holding) return;
    const wait = Math.max(0, MIN_SPIN_MS - (Date.now() - state.since));
    setTimeout(() => {
      state.holding = false;
      setOffset(0, true);
      void animate(indicator.current, [{ transform: "scale(1)" }, { transform: "scale(0.4)" }], { duration: 260, easing: "ease-in" })
        .then(() => {
          if (!live.current.holding) setSpokes(0, false);
        });
    }, wait);
  };

  useEffect(() => {
    const state = live.current;
    if (!refreshing) {
      finish();
    } else if (!state.holding && (page?.scroller.current?.scrollTop ?? 0) <= 0) {
      // Actualizando sin tirar (al abrir, "Try Again"): el indicador igual aparece arriba.
      state.holding = true;
      state.since = Date.now();
      setOffset(REFRESH_HOLD, true);
      setSpokes(1, true);
    }
  }, [refreshing]);

  useEffect(() => {
    const scroller = page?.scroller.current;
    if (!scroller) return;
    let start: { x: number; y: number } | null = null;
    let pulling = false;
    let offset = 0;

    const down = (e: TouchEvent) => {
      if (e.touches.length !== 1 || scroller.scrollTop > 0 || live.current.holding) {
        start = null;
        return;
      }
      const t = e.touches[0]!;
      start = { x: t.clientX, y: t.clientY };
      pulling = false;
      offset = 0;
    };
    const move = (e: TouchEvent) => {
      if (!start) return;
      const t = e.touches[0]!;
      const dy = t.clientY - start.y;
      if (!pulling) {
        if (scroller.scrollTop > 0 || dy <= 0 || Math.abs(t.clientX - start.x) > dy) {
          if (dy < 0 || scroller.scrollTop > 0) start = null;
          return;
        }
        pulling = true;
        screenOf()?.classList.remove("screen--ptr-settle");
      }
      if (e.cancelable) e.preventDefault();
      offset = pullOffset(dy, scroller.clientHeight);
      setOffset(offset, false);
      setSpokes(pullProgress(offset), false);
    };
    const up = () => {
      if (!start) return;
      start = null;
      if (!pulling) return;
      pulling = false;
      if (offset >= REFRESH_THRESHOLD) {
        live.current.holding = true;
        live.current.since = Date.now();
        setOffset(REFRESH_HOLD, true);
        setSpokes(1, true);
        live.current.onRefresh();
        // `refreshing` puede no cambiar nunca (sin conexión): se suelta igual.
        setTimeout(() => {
          if (!live.current.refreshing) finish();
        }, MIN_SPIN_MS);
      } else {
        setOffset(0, true);
        setSpokes(0, false);
      }
    };
    scroller.addEventListener("touchstart", down, { passive: true });
    scroller.addEventListener("touchmove", move, { passive: false });
    scroller.addEventListener("touchend", up);
    scroller.addEventListener("touchcancel", up);
    return () => {
      scroller.removeEventListener("touchstart", down);
      scroller.removeEventListener("touchmove", move);
      scroller.removeEventListener("touchend", up);
      scroller.removeEventListener("touchcancel", up);
    };
  }, [page?.scroller]);

  return (
    <div ref={indicator} class={reducedMotion() ? "ptr ptr--reduced" : "ptr"} aria-hidden="true">
      <svg class="ptr__spinner" width="28" height="28" viewBox="0 0 28 28">
        {Array.from({ length: 8 }, (_, i) => (
          <line key={i} class="ptr__spoke" x1="14" y1="4" x2="14" y2="9.5" transform={`rotate(${i * 45} 14 14)`} />
        ))}
      </svg>
    </div>
  );
}
