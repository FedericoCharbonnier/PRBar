import type { ComponentChildren, RefObject } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { NavUpdate } from "../../app/router";
import { sameRoute, type StackRoute } from "../../app/navstack";
import { routeHash } from "../../app/router";
import type { TabId } from "../screens/types";
import { animate, cancelAnimations, ghost, reducedMotion } from "../motion/animate";
import {
  addSample, DIM, EASE_SPRING, EDGE_WIDTH, gestureAxis, popFrame, PUSH_MS, settleDuration, shouldCompletePop, swipeProgress,
  velocityOf, type Sample,
} from "../motion/math";
import { PageContext } from "./context";
import "./nav.css";

// Las pestañas con su pila de pantallas, como UITabBarController + UINavigationController: cada pantalla es una capa
// con su propio scroll; push entra desde la derecha mientras la de abajo se corre un 30 % y se oscurece; pop al revés;
// el gesto desde el borde izquierdo arrastra la pantalla y decide al soltar. Las pestañas no se deslizan: cada una
// guarda su pila y su scroll. Las pantallas tapadas quedan montadas (invisibles e inertes) para volver a ellas igual.

export interface NavHostProps {
  nav: NavUpdate;
  /** Las pestañas que ya se mostraron (las demás no se montan hasta elegirlas). */
  tabs: TabId[];
  renderRoute: (route: StackRoute, info: { root: boolean; visible: boolean }) => ComponentChildren;
  titleOf: (route: StackRoute) => string;
  onBack: () => void;
}

export function NavHost({ nav, tabs, renderRoute, titleOf, onBack }: NavHostProps) {
  return (
    <div class="nav-host">
      {tabs.map((tab) => (
        <TabStack
          key={tab}
          tab={tab}
          stack={nav.state.stacks[tab]}
          active={nav.state.tab === tab}
          navId={nav.id}
          transition={nav.state.tab === tab ? nav.transition : "none"}
          renderRoute={renderRoute}
          titleOf={titleOf}
          onBack={onBack}
        />
      ))}
    </div>
  );
}

interface TabStackProps {
  tab: TabId;
  stack: StackRoute[];
  active: boolean;
  navId: number;
  transition: NavUpdate["transition"];
  renderRoute: NavHostProps["renderRoute"];
  titleOf: NavHostProps["titleOf"];
  onBack: () => void;
}

/** Lo que quedó del gesto de volver al soltarlo: la animación del pop sigue desde ahí. */
interface Release {
  x: number;
  velocity: number;
}

function pageOf(container: HTMLElement | null, index: number): HTMLElement | null {
  return (container?.querySelector(`:scope > .page[data-index="${index}"]`) as HTMLElement | null) ?? null;
}

function dimOf(page: HTMLElement | null): HTMLElement | null {
  return (page?.querySelector(":scope > .page__dim") as HTMLElement | null) ?? null;
}

function clearInline(...els: (HTMLElement | null)[]) {
  for (const el of els) {
    if (!el) continue;
    el.style.transform = "";
    el.style.opacity = "";
    el.style.willChange = "";
  }
}

function TabStack({ tab, stack, active, navId, transition, renderRoute, titleOf, onBack }: TabStackProps) {
  const container = useRef<HTMLDivElement>(null);
  // La pantalla que sale en un pop se sigue mostrando hasta que termina de salir.
  const exiting = useRef<{ id: number; route: StackRoute | null }>({ id: -1, route: null });
  const previous = useRef<StackRoute[]>(stack);
  const seen = useRef(navId);
  const release = useRef<Release | null>(null);
  const animating = useRef(false);
  const [, rerender] = useState(0);

  if (seen.current !== navId) {
    let leaving: StackRoute | null = null;
    if (transition === "pop" && active) {
      const removed = previous.current.filter((r) => !stack.some((s) => sameRoute(s, r)));
      leaving = removed[removed.length - 1] ?? null;
    }
    exiting.current = { id: navId, route: leaving };
    previous.current = stack;
    seen.current = navId;
  }

  const leaving = exiting.current.route;
  const pages: { route: StackRoute; index: number; exiting: boolean }[] = stack.map((route, index) => ({ route, index, exiting: false }));
  if (leaving) pages.push({ route: leaving, index: stack.length, exiting: true });
  const top = stack.length - 1;

  // ---------- Transiciones ----------
  useLayoutEffect(() => {
    if (!active || (transition !== "push" && transition !== "pop")) {
      release.current = null;
      return;
    }
    const host = container.current;
    const width = host?.clientWidth ?? 0;
    const reduce = reducedMotion();
    const done = () => {
      animating.current = false;
      host?.querySelectorAll(":scope > .page--revealed").forEach((p) => p.classList.remove("page--revealed"));
    };
    animating.current = true;
    if (transition === "push") {
      const incoming = pageOf(host, top);
      const under = pageOf(host, top - 1);
      under?.classList.add("page--revealed");
      const jobs = reduce
        ? [animate(incoming, [{ opacity: 0 }, { opacity: 1 }], { duration: 220 })]
        : [
            animate(incoming, [{ transform: `translate3d(${width}px,0,0)` }, { transform: "translate3d(0,0,0)" }], { duration: PUSH_MS, easing: EASE_SPRING }),
            animate(under, [{ transform: "translate3d(0,0,0)" }, { transform: `translate3d(${-width * 0.3}px,0,0)` }], { duration: PUSH_MS, easing: EASE_SPRING }),
            animate(dimOf(under), [{ opacity: 0 }, { opacity: DIM }], { duration: PUSH_MS, easing: EASE_SPRING }),
          ];
      void Promise.all(jobs).then(done);
      return;
    }
    // pop: la que sale es la de índice `top + 1` (si quedó montada); la de abajo vuelve desde el paralaje.
    const outgoing = pageOf(host, top + 1);
    const under = pageOf(host, top);
    under?.classList.add("page--revealed");
    const from = release.current;
    release.current = null;
    const startX = from?.x ?? 0;
    const frame = popFrame(swipeProgress(startX, width), width);
    const duration = from ? settleDuration(width - startX, from.velocity, 160, PUSH_MS) : PUSH_MS;
    const easing = from ? "cubic-bezier(0.2, 0.8, 0.3, 1)" : EASE_SPRING;
    clearInline(outgoing, under, dimOf(under));
    const jobs = reduce && !from
      ? [animate(outgoing, [{ opacity: 1 }, { opacity: 0 }], { duration: 220, hold: true })]
      : [
          animate(outgoing, [{ transform: `translate3d(${startX}px,0,0)` }, { transform: `translate3d(${width}px,0,0)` }], { duration, easing, hold: true }),
          animate(under, [{ transform: `translate3d(${frame.underX}px,0,0)` }, { transform: "translate3d(0,0,0)" }], { duration, easing }),
          animate(dimOf(under), [{ opacity: frame.dim }, { opacity: 0 }], { duration, easing }),
        ];
    void Promise.all(jobs).then(() => {
      done();
      if (exiting.current.id === navId) {
        exiting.current = { id: navId, route: null };
        rerender((n) => n + 1);
      }
    });
  }, [navId]);

  // ---------- Gesto de volver desde el borde ----------
  const canSwipe = active && stack.length > 1 && !leaving;
  useEffect(() => {
    const host = container.current;
    if (!host || !canSwipe) return;
    let state: { id: number; x0: number; y0: number; samples: Sample[]; axis: "x" | "y" | null; width: number } | null = null;
    let topPage: HTMLElement | null = null;
    let under: HTMLElement | null = null;

    const apply = (dx: number) => {
      const width = state!.width;
      const f = popFrame(swipeProgress(dx, width), width);
      if (topPage) topPage.style.transform = `translate3d(${f.topX}px,0,0)`;
      if (under) under.style.transform = `translate3d(${f.underX}px,0,0)`;
      const dim = dimOf(under);
      if (dim) dim.style.opacity = String(f.dim);
    };

    const down = (e: PointerEvent) => {
      if (state || animating.current || !e.isPrimary) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      const rect = host.getBoundingClientRect();
      if (e.clientX - rect.left > EDGE_WIDTH) return;
      state = { id: e.pointerId, x0: e.clientX, y0: e.clientY, samples: [{ t: e.timeStamp, v: 0 }], axis: null, width: rect.width };
    };

    const move = (e: PointerEvent) => {
      if (!state || e.pointerId !== state.id) return;
      const dx = e.clientX - state.x0;
      const dy = e.clientY - state.y0;
      if (!state.axis) {
        state.axis = gestureAxis(dx, dy);
        if (state.axis === "y" || (state.axis === "x" && dx < 0)) {
          state = null;
          return;
        }
        if (state.axis !== "x") return;
        topPage = pageOf(host, stack.length - 1);
        under = pageOf(host, stack.length - 2);
        cancelAnimations(topPage);
        cancelAnimations(under);
        under?.classList.add("page--revealed");
        for (const el of [topPage, under]) if (el) el.style.willChange = "transform";
        host.classList.add("stack--dragging");
        try {
          host.setPointerCapture(e.pointerId);
        } catch {
          // Eventos sintéticos: no hay captura.
        }
      }
      if (e.cancelable) e.preventDefault();
      state.samples = addSample(state.samples, e.timeStamp, Math.max(0, dx));
      apply(Math.max(0, dx));
    };

    const up = (e: PointerEvent) => {
      if (!state || e.pointerId !== state.id) return;
      const current = state;
      state = null;
      if (current.axis !== "x") return;
      host.classList.remove("stack--dragging");
      const dx = Math.max(0, e.clientX - current.x0);
      const velocity = e.type === "pointercancel" ? 0 : velocityOf(current.samples);
      const width = current.width;
      if (e.type !== "pointercancel" && shouldCompletePop(dx, velocity, width)) {
        // El pop sigue la animación desde donde quedó el dedo (useLayoutEffect de arriba).
        release.current = { x: dx, velocity };
        animating.current = true;
        onBack();
        // Si el pop no llega (no debería), la pantalla vuelve a su lugar.
        setTimeout(() => {
          if (release.current) {
            release.current = null;
            animating.current = false;
            clearInline(topPage, under, dimOf(under));
            under?.classList.remove("page--revealed");
          }
        }, 1200);
        return;
      }
      const f = popFrame(swipeProgress(dx, width), width);
      const duration = settleDuration(dx, velocity, 160, 320);
      const t = topPage;
      const u = under;
      animating.current = true;
      clearInline(t, u, dimOf(u));
      void Promise.all([
        animate(t, [{ transform: `translate3d(${f.topX}px,0,0)` }, { transform: "translate3d(0,0,0)" }], { duration, easing: EASE_SPRING }),
        animate(u, [{ transform: `translate3d(${f.underX}px,0,0)` }, { transform: `translate3d(${-width * 0.3}px,0,0)` }], { duration, easing: EASE_SPRING }),
        animate(dimOf(u), [{ opacity: f.dim }, { opacity: DIM }], { duration, easing: EASE_SPRING }),
      ]).then(() => {
        animating.current = false;
        u?.classList.remove("page--revealed");
      });
    };

    host.addEventListener("pointerdown", down);
    host.addEventListener("pointermove", move);
    host.addEventListener("pointerup", up);
    host.addEventListener("pointercancel", up);
    return () => {
      host.removeEventListener("pointerdown", down);
      host.removeEventListener("pointermove", move);
      host.removeEventListener("pointerup", up);
      host.removeEventListener("pointercancel", up);
    };
  }, [canSwipe, stack.length]);

  return (
    <div ref={container} class={`stack${active ? " stack--active" : " stack--inactive"}${canSwipe ? " stack--swipe" : ""}`} data-tab={tab} aria-hidden={active ? undefined : "true"}>
      {pages.map(({ route, index, exiting: out }) => {
        const visible = active && !out && index === top;
        const below = index > 0 ? (index - 1 < stack.length ? stack[index - 1] : undefined) : undefined;
        return (
          <Page
            key={routeHash(route)}
            index={index}
            root={index === 0}
            visible={visible}
            covered={!out && index < top}
            exiting={out}
            backTitle={below ? titleOf(below) : undefined}
          >
            {renderRoute(route, { root: index === 0, visible })}
          </Page>
        );
      })}
    </div>
  );
}

function Page({ index, root, visible, covered, exiting, backTitle, children }: {
  index: number; root: boolean; visible: boolean; covered: boolean; exiting: boolean; backTitle?: string | undefined;
  children: ComponentChildren;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const page = useRef<HTMLElement>(null);
  useScrollChrome(page, scroller);
  useContentFade(scroller);
  const cls = ["page"];
  if (root) cls.push("page--root");
  if (covered) cls.push("page--covered");
  if (exiting) cls.push("page--exiting");
  const hidden = covered || exiting || !visible;
  return (
    <section ref={page} class={cls.join(" ")} data-index={index} aria-hidden={hidden ? "true" : undefined} inert={hidden}>
      <div ref={scroller} class="page__scroll">
        <PageContext.Provider value={{ backTitle, scroller, visible }}>{children}</PageContext.Provider>
      </div>
      <div class="page__dim" aria-hidden="true" />
    </section>
  );
}

/** Lo que llega después de abierta la pantalla (los datos de la Mac, un mensaje, una tarjeta nueva) aparece con un
 *  fundido corto en lugar de saltar. Lo que ya estaba al entrar no se anima (entra con la transición). */
const FADE_IN = ".card, .summary-card, .finding, .progress-card, .feedback, .check, .diff, .reply-card, .offline-card, .banner, " +
  ".empty, .stats, .spend, .start-btn, .description-card, .file-chips, .bubble-row, .action-card, .typing, .detail-head";

function useContentFade(scroller: RefObject<HTMLElement>): void {
  useEffect(() => {
    const el = scroller.current;
    if (!el || typeof MutationObserver !== "function") return;
    let ready = false;
    const timer = setTimeout(() => (ready = true), PUSH_MS + 100);
    const observer = new MutationObserver((records) => {
      if (!ready || reducedMotion()) return;
      for (const r of records) {
        r.addedNodes.forEach((node) => {
          if (!(node instanceof HTMLElement) || !node.matches(FADE_IN) || node.classList.contains("ghost")) return;
          const chat = node.classList.contains("bubble-row") || node.classList.contains("action-card");
          void animate(node, chat
            ? [{ opacity: 0, transform: "translate3d(0, 12px, 0) scale(0.97)" }, { opacity: 1, transform: "none" }]
            : [{ opacity: 0 }, { opacity: 1 }], { duration: chat ? 340 : 260, easing: chat ? EASE_SPRING : "ease-out" });
        });
      }
    });
    observer.observe(el, { childList: true, subtree: true });
    return () => {
      clearTimeout(timer);
      observer.disconnect();
    };
  }, []);
}

/** La barra de navegación según el scroll: material translúcido con línea cuando hay contenido debajo
 *  (`data-scrolled`) y el título en línea cuando el título grande ya pasó debajo de la barra (`data-collapsed`). */
export function useScrollChrome(page: RefObject<HTMLElement>, scroller: RefObject<HTMLElement>): void {
  useEffect(() => {
    const el = scroller.current;
    const root = page.current;
    if (!el || !root) return;
    let frame = 0;
    let threshold: number | null = null;
    const measure = (): number => {
      const title = el.querySelector(".large-title, .detail-head__title") as HTMLElement | null;
      const bar = el.querySelector(".navbar, .topbar") as HTMLElement | null;
      if (!title || !bar) return Infinity;
      const base = el.getBoundingClientRect().top - el.scrollTop;
      const titleBottom = title.getBoundingClientRect().bottom - base;
      const barBottom = bar.getBoundingClientRect().bottom - el.getBoundingClientRect().top;
      return Math.max(1, titleBottom - barBottom);
    };
    const update = () => {
      frame = 0;
      const y = el.scrollTop;
      if (threshold === null) threshold = measure();
      root.toggleAttribute("data-scrolled", y > 0.5);
      root.toggleAttribute("data-collapsed", y >= threshold);
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(update);
    };
    const onResize = () => {
      threshold = null;
      onScroll();
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    addEventListener("resize", onResize);
    // El contenido cambia (llegan los datos): se vuelve a medir.
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(onResize) : null;
    if (el.firstElementChild) observer?.observe(el.firstElementChild);
    update();
    return () => {
      el.removeEventListener("scroll", onScroll);
      removeEventListener("resize", onResize);
      observer?.disconnect();
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);
}

/** Una pantalla sola, fuera de las pestañas (el emparejamiento): misma capa con scroll propio. Al cambiar `id` la nueva
 *  entra con un fundido corto y la anterior se va encima con otro (como un cambio de raíz en UIKit). */
export function SoloPage({ id, children }: { id: string; children: ComponentChildren }) {
  return (
    <div class="nav-host">
      <div class="stack stack--active">
        <SoloLayer key={id}>{children}</SoloLayer>
      </div>
    </div>
  );
}

function SoloLayer({ children }: { children: ComponentChildren }) {
  const page = useRef<HTMLElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const mounted = useRef(false);
  useScrollChrome(page, scroller);
  useLayoutEffect(() => {
    const el = page.current;
    if (mounted.current) return;
    mounted.current = true;
    // El primer render de la app no se anima.
    if (document.documentElement.dataset["booted"] !== "true") {
      document.documentElement.dataset["booted"] = "true";
    } else {
      void animate(el, [{ opacity: 0, transform: "scale(0.985)" }, { opacity: 1, transform: "none" }], { duration: 320, easing: EASE_SPRING });
    }
    return () => ghost(el, () => [{ opacity: 1 }, { opacity: 0 }], { duration: 220, easing: "ease-out" });
  }, []);
  return (
    <section ref={page} class="page page--root">
      <div ref={scroller} class="page__scroll">
        <PageContext.Provider value={{ scroller, visible: true }}>{children}</PageContext.Provider>
      </div>
    </section>
  );
}
