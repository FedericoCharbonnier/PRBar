import { signal, type ReadonlySignal } from "@preact/signals";
import { isPRId } from "../protocol/commands";
import type { TabId } from "../ui/screens/types";
import {
  initialNav, isStackRoute, navigate, pop, popToRoot, push, replaceTop, selectTab, topRoute, type NavChange,
} from "./navstack";

// Rutas por hash (spec W.2) con los ids de pantalla del diseño:
//   #/home  #/mine  #/activity  #/settings
//   #/pr/<owner>/<repo>/<n>[/review|respond|fixci|diff|merge|chat[/review|respond|merge]]
//   #/pair                   (emparejar desde la app)
//   #pair?v=1&r=…            (el link del QR de emparejamiento, W.4.4: se confirma antes de usarlo)
// El fragmento nunca llega al servidor.

export type PRScreenId = "review" | "respond" | "fixci" | "diff" | "merge" | "chat";
export type ChatKind = "review" | "respond" | "merge";

export type Route =
  | { kind: "tab"; tab: TabId }
  /** `screen` ausente: la pantalla que corresponde a la sección del PR (`defaultScreen`). */
  | { kind: "pr"; pr: string; screen?: PRScreenId | undefined; chat?: ChatKind | undefined;
      /** respond:diff abierto desde un archivo (Fix CI): ese archivo elegido. */
      file?: string | undefined }
  | { kind: "pair" }
  /** El texto completo del link de emparejamiento (`https://<host>/#pair?…`). */
  | { kind: "pairLink"; link: string };

const TAB_HASH: Record<TabId, string> = { review: "#/home", mine: "#/mine", activity: "#/activity", settings: "#/settings" };
const SCREENS: readonly string[] = ["review", "respond", "fixci", "diff", "merge", "chat"];
const CHATS: readonly string[] = ["review", "respond", "merge"];

export const HOME: Route = { kind: "tab", tab: "review" };

/** `origin` arma el link de emparejamiento completo a partir del fragmento (`#pair?…`). */
export function parseRoute(hash: string, origin = "https://localhost"): Route {
  if (hash.startsWith("#pair?")) return { kind: "pairLink", link: `${origin}/${hash}` };
  const [rawPath, query] = hash.replace(/^#\/?/, "").split("?");
  const path = rawPath!.replace(/\/+$/, "");
  const parts = path.split("/").map((p) => {
    try {
      return decodeURIComponent(p);
    } catch {
      return "";
    }
  });
  switch (parts[0]) {
    case "":
    case "home":
      return HOME;
    case "mine":
      return { kind: "tab", tab: "mine" };
    case "activity":
      return { kind: "tab", tab: "activity" };
    case "settings":
      return { kind: "tab", tab: "settings" };
    case "pair":
      return { kind: "pair" };
    case "pr": {
      const [, owner, repo, number, screen, chat] = parts;
      const pr = `${owner}/${repo}#${number}`;
      if (!owner || !repo || !number || !isPRId(pr) || /^\.+$/.test(owner) || /^\.+$/.test(repo)) return HOME;
      if (screen === undefined) return { kind: "pr", pr };
      if (!SCREENS.includes(screen)) return { kind: "pr", pr };
      if (screen === "chat" && chat !== undefined && CHATS.includes(chat)) {
        return { kind: "pr", pr, screen: "chat", chat: chat as ChatKind };
      }
      if (screen === "diff") {
        const file = new URLSearchParams(query ?? "").get("file");
        if (file) return { kind: "pr", pr, screen: "diff", file };
      }
      return { kind: "pr", pr, screen: screen as PRScreenId };
    }
    default:
      return HOME;
  }
}

export function routeHash(route: Route): string {
  switch (route.kind) {
    case "tab":
      return TAB_HASH[route.tab];
    case "pair":
      return "#/pair";
    case "pairLink":
      return route.link.slice(route.link.indexOf("#"));
    case "pr": {
      const { repo, number } = splitId(route.pr);
      const [owner, name] = repo.split("/");
      let hash = `#/pr/${encodeURIComponent(owner ?? "")}/${encodeURIComponent(name ?? "")}/${number}`;
      if (route.screen) hash += `/${route.screen}`;
      if (route.screen === "chat" && route.chat) hash += `/${route.chat}`;
      if (route.screen === "diff" && route.file) hash += `?file=${encodeURIComponent(route.file)}`;
      return hash;
    }
  }
}

function splitId(pr: string): { repo: string; number: string } {
  const at = pr.lastIndexOf("#");
  return { repo: pr.slice(0, at), number: pr.slice(at + 1) };
}

/** La pestaña a la que pertenece una ruta (la que queda marcada en la barra). */
export function routeTab(route: Route, mine: (pr: string) => boolean): TabId {
  if (route.kind === "tab") return route.tab;
  if (route.kind === "pr") return mine(route.pr) ? "mine" : "review";
  return "review";
}

/** Adónde vuelve "Back" desde una ruta sin historial (abierta desde una notificación). */
export function parentRoute(route: Route, mine: (pr: string) => boolean): Route {
  if (route.kind === "pr" && route.screen === "diff") return { kind: "pr", pr: route.pr, screen: "respond" };
  if (route.kind === "pr" && route.screen === "chat") {
    const screen = route.chat === "merge" ? "merge" : route.chat === "respond" ? "respond" : "review";
    return { kind: "pr", pr: route.pr, screen };
  }
  return { kind: "tab", tab: routeTab(route, mine) };
}

export interface HistoryLike {
  readonly state: unknown;
  pushState(data: unknown, unused: string, url?: string): void;
  replaceState(data: unknown, unused: string, url?: string): void;
  back(): void;
}

export interface LocationLike {
  readonly hash: string;
  /** `host[:puerto]` de la página. */
  readonly host: string;
}

/** Un cambio de navegación: el estado de las pilas, cómo animarlo y un número que sube con cada cambio. */
export interface NavUpdate extends NavChange {
  id: number;
}

/** El router de la app: una signal con la ruta actual y otra con las pilas de cada pestaña (`navstack.ts`), con
 *  `go`/`replace`/`back`/`tab` sobre `history`. Cada entrada propia guarda su profundidad: "Back" sin nada atrás (una
 *  notificación abrió la app ahí, o se cambió de pestaña) vuelve en la pila sin tocar el historial. */
export class Router {
  readonly #route = signal<Route>(HOME);
  readonly #nav = signal<NavUpdate>({ state: initialNav(HOME, () => false), transition: "none", id: 0 });
  readonly #history: HistoryLike;
  readonly #location: LocationLike;
  #mine: (pr: string) => boolean = () => false;

  constructor(history: HistoryLike, location: LocationLike) {
    this.#history = history;
    this.#location = location;
    this.sync();
    this.#nav.value = { state: initialNav(this.#route.value, this.#mine), transition: "none", id: 0 };
  }

  get route(): ReadonlySignal<Route> {
    return this.#route;
  }

  /** Las pilas de las pestañas y la última transición. */
  get nav(): ReadonlySignal<NavUpdate> {
    return this.#nav;
  }

  /** Para saber qué PRs son "míos" (la pestaña y el padre de una ruta). Rearma las pilas desde la ruta actual. */
  setMine(mine: (pr: string) => boolean): void {
    this.#mine = mine;
    this.#apply({ state: initialNav(this.#route.value, mine), transition: "none" });
  }

  #apply(change: NavChange): void {
    this.#nav.value = { ...change, id: this.#nav.value.id + 1 };
  }

  /** Lee la ruta de `location.hash` (al arrancar y en `hashchange`/`popstate`). */
  sync(): void {
    // El link de emparejamiento se arma con el host de esta página: `parsePairingURL` exige que sea el del relay del
    // QR (`r`), así un link no puede mandar a otro relay. Siempre `https://` (el texto que imprime la Mac).
    const route = parseRoute(this.#location.hash, `https://${this.#location.host}`);
    this.#route.value = route;
    const change = navigate(this.#nav.peek().state, route, this.#mine);
    if (change.state !== this.#nav.peek().state) this.#apply(change);
  }

  get depth(): number {
    const state = this.#history.state as { prbarDepth?: unknown } | null;
    return typeof state?.prbarDepth === "number" ? state.prbarDepth : 0;
  }

  go(route: Route): void {
    const hash = routeHash(route);
    if (hash === routeHash(this.#route.value)) return;
    this.#history.pushState({ prbarDepth: this.depth + 1 }, "", hash);
    this.#route.value = route;
    if (isStackRoute(route)) this.#apply(push(this.#nav.peek().state, route, this.#mine));
  }

  replace(route: Route): void {
    this.#history.replaceState({ prbarDepth: this.depth }, "", routeHash(route));
    this.#route.value = route;
    if (isStackRoute(route)) this.#apply(replaceTop(this.#nav.peek().state, route, this.#mine));
  }

  /** La barra de pestañas: cambia de pestaña conservando su pila; en la pestaña elegida vuelve a la raíz. */
  tab(tab: TabId): void {
    this.#show(selectTab(this.#nav.peek().state, tab));
  }

  /** Vuelve hasta la raíz de la pestaña actual. */
  popToRoot(): void {
    this.#show(popToRoot(this.#nav.peek().state));
  }

  /** Muestra un estado nuevo sin apilar en el historial (la entrada actual pasa a ser la pantalla de arriba). */
  #show(change: NavChange): void {
    const top = topRoute(change.state);
    this.#history.replaceState({ prbarDepth: 0 }, "", routeHash(top));
    this.#route.value = top;
    this.#apply(change);
  }

  back(): void {
    if (this.depth > 0) {
      this.#history.back();
      return;
    }
    const change = pop(this.#nav.peek().state, this.#mine);
    if (change.transition !== "none") this.#show(change);
  }

  get currentTab(): TabId {
    return this.#nav.value.state.tab;
  }
}
