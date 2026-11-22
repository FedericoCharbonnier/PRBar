import type { TabId } from "../ui/screens/types";
import { parentRoute, routeHash, type Route } from "./router";

// La pila de navegación de cada pestaña (como un UINavigationController por pestaña dentro de un UITabBarController).
// Funciones puras: el router las usa para saber qué pila mostrar y cómo animar el cambio (push, pop o pestaña).

export const TABS: readonly TabId[] = ["review", "mine", "activity", "settings"];

/** Las rutas que se apilan: la raíz de una pestaña y las pantallas de PR. */
export type StackRoute = Extract<Route, { kind: "tab" } | { kind: "pr" }>;

export interface NavState {
  tab: TabId;
  /** Una pila por pestaña; la primera ruta es siempre la raíz de la pestaña. */
  stacks: Record<TabId, StackRoute[]>;
}

/** Cómo se pasa de una pantalla a otra: deslizar desde la derecha, volver, cambio de pestaña (sin deslizar) o nada. */
export type Transition = "none" | "push" | "pop" | "tab";

export interface NavChange {
  state: NavState;
  transition: Transition;
}

type Mine = (pr: string) => boolean;

export function isStackRoute(route: Route): route is StackRoute {
  return route.kind === "tab" || route.kind === "pr";
}

export function tabRoot(tab: TabId): StackRoute {
  return { kind: "tab", tab };
}

export function sameRoute(a: Route, b: Route): boolean {
  return routeHash(a) === routeHash(b);
}

/** La pestaña natural de una ruta: la suya si es raíz; la de "mis PRs" o "para revisar" si es de un PR. */
export function naturalTab(route: StackRoute, mine: Mine): TabId {
  if (route.kind === "tab") return route.tab;
  return mine(route.pr) ? "mine" : "review";
}

/** La cadena desde la raíz hasta `route` siguiendo las rutas padre (una ruta abierta desde una notificación). */
export function chainFor(route: StackRoute, mine: Mine): StackRoute[] {
  const chain: StackRoute[] = [route];
  let current: Route = route;
  for (let i = 0; i < 8 && current.kind !== "tab"; i++) {
    const parent = parentRoute(current, mine);
    if (!isStackRoute(parent)) break;
    chain.unshift(parent);
    current = parent;
  }
  if (chain[0]!.kind !== "tab") chain.unshift(tabRoot(naturalTab(route, mine)));
  return chain;
}

export function initialNav(route: Route, mine: Mine): NavState {
  const stacks = Object.fromEntries(TABS.map((t) => [t, [tabRoot(t)]])) as Record<TabId, StackRoute[]>;
  if (!isStackRoute(route)) return { tab: "review", stacks };
  const chain = chainFor(route, mine);
  const tab = (chain[0] as Extract<StackRoute, { kind: "tab" }>).tab;
  stacks[tab] = chain;
  return { tab, stacks };
}

export function currentStack(state: NavState): StackRoute[] {
  return state.stacks[state.tab];
}

export function topRoute(state: NavState): StackRoute {
  const stack = currentStack(state);
  return stack[stack.length - 1]!;
}

function withStack(state: NavState, tab: TabId, stack: StackRoute[]): NavState {
  return { tab, stacks: { ...state.stacks, [tab]: stack } };
}

/** Apila `route` (un toque en una fila, "Chat"). Una pantalla de PR desde Activity o Settings va a su pestaña. */
export function push(state: NavState, route: StackRoute, mine: Mine): NavChange {
  if (sameRoute(topRoute(state), route)) return { state, transition: "none" };
  if (route.kind === "tab") return selectRoot(state, route.tab);
  const tab = state.tab === "review" || state.tab === "mine" ? state.tab : naturalTab(route, mine);
  const next = withStack(state, tab, [...state.stacks[tab], route]);
  return { state: next, transition: tab === state.tab ? "push" : "tab" };
}

/** Vuelve una pantalla (Back, el gesto desde el borde). */
export function pop(state: NavState, mine: Mine): NavChange {
  const stack = currentStack(state);
  if (stack.length > 1) return { state: withStack(state, state.tab, stack.slice(0, -1)), transition: "pop" };
  const only = stack[0]!;
  if (only.kind === "tab") return { state, transition: "none" };
  // Una pila sin raíz no debería existir (chainFor), pero por las dudas: la ruta padre.
  const chain = chainFor(only, mine);
  return { state: withStack(state, state.tab, chain.slice(0, -1)), transition: "pop" };
}

/** Vuelve hasta la raíz de la pestaña actual (tocar la pestaña elegida). */
export function popToRoot(state: NavState): NavChange {
  const stack = currentStack(state);
  if (stack.length <= 1) return { state, transition: "none" };
  return { state: withStack(state, state.tab, stack.slice(0, 1)), transition: "pop" };
}

/** Cambia de pestaña conservando su pila (la barra de pestañas). */
export function selectTab(state: NavState, tab: TabId): NavChange {
  if (tab === state.tab) return popToRoot(state);
  return { state: { ...state, tab }, transition: "tab" };
}

function selectRoot(state: NavState, tab: TabId): NavChange {
  if (tab === state.tab) return popToRoot(state);
  return { state: withStack(state, tab, [tabRoot(tab)]), transition: "tab" };
}

/** Reemplaza la pantalla de arriba (sin animar). */
export function replaceTop(state: NavState, route: StackRoute, mine: Mine): NavChange {
  if (route.kind === "tab") {
    return { state: withStack(state, route.tab, [route]), transition: route.tab === state.tab ? "none" : "tab" };
  }
  const stack = [...currentStack(state).slice(0, -1), route];
  const next = stack[0]!.kind === "tab" ? stack : chainFor(route, mine);
  return { state: withStack(state, state.tab, next), transition: "none" };
}

/** La ruta cambió desde afuera (el hash, `popstate`, un link): se busca en las pilas. Si está debajo en la pila actual
 *  es un pop; si está en otra pestaña se cambia a esa pestaña y se corta su pila ahí; si no, se apila. */
export function navigate(state: NavState, route: Route, mine: Mine): NavChange {
  if (!isStackRoute(route)) return { state, transition: "none" };
  const stack = currentStack(state);
  const here = stack.findIndex((r) => sameRoute(r, route));
  if (here === stack.length - 1) return { state, transition: "none" };
  if (here >= 0) return { state: withStack(state, state.tab, stack.slice(0, here + 1)), transition: "pop" };
  if (route.kind === "tab") return selectRoot(state, route.tab);
  for (const tab of TABS) {
    if (tab === state.tab) continue;
    const index = state.stacks[tab].findIndex((r) => sameRoute(r, route));
    if (index >= 0) return { state: withStack(state, tab, state.stacks[tab].slice(0, index + 1)), transition: "tab" };
  }
  return push(state, route, mine);
}

/** El título corto de cada pantalla (el botón Back de la pantalla siguiente lo muestra). */
export function routeTitle(route: StackRoute, screen = route.kind === "pr" ? route.screen : undefined): string {
  if (route.kind === "tab") {
    return { review: "To Review", mine: "My PRs", activity: "Activity", settings: "Settings" }[route.tab];
  }
  switch (screen) {
    case "respond":
      return "Respond";
    case "fixci":
      return "Fix CI";
    case "diff":
      return "Changes";
    case "merge":
      return "Merge";
    case "chat":
      return "Claude";
    default:
      return "Review";
  }
}
