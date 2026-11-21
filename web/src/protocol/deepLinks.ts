import { isPRId } from "./commands";

// Los links que manda la Mac en los pushes (R.3, Q.4) siguen siendo `prbar://…`; la web app navega por hash (W.2):
// `prbar://pr/<o>/<r>/<n>?screen=review` → `#/pr/<o>/<r>/<n>/review`, `prbar://activity` → `#/activity`,
// `prbar://home` → `#/home`. Cualquier otro (`prbar://pair`, un esquema distinto) no es destino de una notificación.

export type PRScreen = "review" | "respond" | "merge" | "chat";
const SCREENS: readonly string[] = ["review", "respond", "merge", "chat"];

export type DeepLink =
  | { kind: "home" }
  | { kind: "activity" }
  | { kind: "pr"; owner: string; repo: string; number: number; screen?: PRScreen };

export function parseDeepLink(link: string): DeepLink | null {
  const match = /^prbar:\/\/([^?#]*)(?:\?([^#]*))?$/.exec(link.trim());
  if (!match) return null;
  const path = match[1]!.replace(/\/+$/, "");
  const query = new URLSearchParams(match[2] ?? "");
  if (path === "home") return { kind: "home" };
  if (path === "activity") return { kind: "activity" };
  const parts = path.split("/");
  if (parts.length !== 4 || parts[0] !== "pr") return null;
  const [, owner, repo, number] = parts as [string, string, string, string];
  if (!isPRId(`${owner}/${repo}#${number}`)) return null;
  const screen = query.get("screen");
  if (screen !== null && !SCREENS.includes(screen)) return { kind: "pr", owner, repo, number: Number(number) };
  return screen === null
    ? { kind: "pr", owner, repo, number: Number(number) }
    : { kind: "pr", owner, repo, number: Number(number), screen: screen as PRScreen };
}

export function deepLinkRoute(link: DeepLink): string {
  switch (link.kind) {
    case "home":
      return "#/home";
    case "activity":
      return "#/activity";
    case "pr": {
      const base = `#/pr/${link.owner}/${link.repo}/${link.number}`;
      return link.screen ? `${base}/${link.screen}` : base;
    }
  }
}

/** La ruta por hash de un link de la Mac; `null` si no es destino de una notificación. */
export function deepLinkToHash(link: string): string | null {
  const parsed = parseDeepLink(link);
  return parsed ? deepLinkRoute(parsed) : null;
}
