import { signal, type ReadonlySignal } from "@preact/signals";
import { isPRId } from "../protocol/commands";
import type { TabId } from "../ui/screens/types";

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
  | { kind: "pr"; pr: string; screen?: PRScreenId | undefined; chat?: ChatKind | undefined }
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
  const path = hash.replace(/^#\/?/, "").split("?")[0]!.replace(/\/+$/, "");
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

/** El router de la app: una signal con la ruta actual, `go`/`replace`/`back` sobre `history`. Cada entrada propia
 *  guarda su profundidad: "Back" sin nada atrás (una notificación abrió la app ahí) reemplaza por la ruta padre. */
export class Router {
  readonly #route = signal<Route>(HOME);
  readonly #history: HistoryLike;
  readonly #location: LocationLike;
  #mine: (pr: string) => boolean = () => false;

  constructor(history: HistoryLike, location: LocationLike) {
    this.#history = history;
    this.#location = location;
    this.sync();
  }

  get route(): ReadonlySignal<Route> {
    return this.#route;
  }

  /** Para saber qué PRs son "míos" (la pestaña y el padre de una ruta). */
  setMine(mine: (pr: string) => boolean): void {
    this.#mine = mine;
  }

  /** Lee la ruta de `location.hash` (al arrancar y en `hashchange`/`popstate`). */
  sync(): void {
    // El link de emparejamiento se arma con el host de esta página: `parsePairingURL` exige que sea el del relay del
    // QR (`r`), así un link no puede mandar a otro relay. Siempre `https://` (el texto que imprime la Mac).
    this.#route.value = parseRoute(this.#location.hash, `https://${this.#location.host}`);
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
  }

  replace(route: Route): void {
    this.#history.replaceState({ prbarDepth: this.depth }, "", routeHash(route));
    this.#route.value = route;
  }

  /** Cambia de pestaña: vuelve a su raíz sin apilar. */
  tab(tab: TabId): void {
    this.#history.replaceState({ prbarDepth: 0 }, "", routeHash({ kind: "tab", tab }));
    this.#route.value = { kind: "tab", tab };
  }

  back(): void {
    if (this.depth > 0) {
      this.#history.back();
      return;
    }
    this.replace(parentRoute(this.#route.value, this.#mine));
  }

  get currentTab(): TabId {
    return routeTab(this.#route.value, this.#mine);
  }
}
