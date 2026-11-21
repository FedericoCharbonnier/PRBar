import { computed, signal, type ReadonlySignal } from "@preact/signals";
import type { PopoverSection, PRInfo, RemoteHome } from "../../protocol/commands";
import type { BannerVM, HomeProps, MacInfo, OfflineCardVM, PRAction, PRRowVM, PRSectionVM, PRStatusLine } from "../../ui/screens/types";
import type { LinkState } from "../../transport/Transport";
import { ActionFailure } from "../actions";
import type { AppContext } from "../context";
import { age, ago, count, dayAndTime, parseDate, person, repoName, time } from "../format";
import type { PRScreenId, Route } from "../router";
import type { AppStore } from "../store";

// home (To Review), home:mine (My PRs) y home:offline (HomeModel.swift): las dos pestañas del popover de la Mac, en
// vivo; con la Mac dormida o sin relay, lo cacheado en gris y las acciones apagadas.

export type HomeTab = "review" | "mine";

const SECTION_TITLES: Record<PopoverSection, string> = {
  toReview: "To Review",
  updatedSinceMyReview: "Updated Since My Review",
  otherToReview: "Other",
  myFeedback: "My PRs with Feedback",
  readyToMerge: "Ready to Merge",
  waitingForReview: "Waiting for Review",
};
const QUIET: readonly string[] = ["otherToReview", "waitingForReview"];
const ORDER: Record<HomeTab, PopoverSection[]> = {
  review: ["toReview", "updatedSinceMyReview", "otherToReview"],
  mine: ["myFeedback", "readyToMerge", "waitingForReview"],
};
export const CI_FAILING = "ciFailing";
const REVIEW_RUNNING = ["queued", "preparing", "reviewing", "filtering"];
const RESPOND_IDLE = ["ready", "done", "failed", "readyToPush"];

function sectionTab(section: PopoverSection | undefined): HomeTab | undefined {
  if (!section) return undefined;
  return ["toReview", "updatedSinceMyReview", "otherToReview"].includes(section) ? "review" : "mine";
}

function prTab(pr: PRInfo): HomeTab | undefined {
  if (pr.tab) return pr.tab === "mine" ? "mine" : "review";
  return sectionTab(pr.section);
}

interface RowData {
  pr: PRInfo;
  section: PopoverSection | null;
}

export interface HomeSection {
  id: string;
  title: string;
  quiet: boolean;
  rows: RowData[];
}

/** Las secciones de una pestaña (en el orden de la Mac; "CI Failing" va antes de "Waiting for Review"). */
export function homeSections(home: RemoteHome | null, tab: HomeTab): HomeSection[] {
  if (!home) return [];
  const failing = new Set(home.ci.map((c) => c.pr));
  const prs = home.prs.filter((pr) => prTab(pr) === tab);
  const result: HomeSection[] = [];
  for (const section of ORDER[tab]) {
    if (section === "waitingForReview") {
      const ci = prs.filter((pr) => failing.has(pr.id));
      if (ci.length > 0) result.push({ id: CI_FAILING, title: "CI Failing", quiet: false, rows: ci.map((pr) => ({ pr, section: null })) });
    }
    const members = prs.filter((pr) => pr.section === section && !(tab === "mine" && failing.has(pr.id)));
    if (members.length === 0) continue;
    result.push({ id: section, title: SECTION_TITLES[section], quiet: QUIET.includes(section),
                  rows: members.map((pr) => ({ pr, section })) });
  }
  return result;
}

/** El número de la pestaña (`tabCounts`; To Review lo muestra como insignia roja). */
export function tabCount(home: RemoteHome | null, tab: HomeTab): number {
  const key = tab === "review" ? "to-review" : "mine";
  const fromMac = home?.status.tabCounts?.[key];
  if (fromMac !== undefined) return fromMac;
  return homeSections(home, tab).filter((s) => !s.quiet).reduce((n, s) => n + s.rows.length, 0);
}

interface RowParts {
  leading: PRRowVM["leading"];
  status?: PRStatusLine;
  action?: PRAction;
}

function rowParts(store: AppStore, home: RemoteHome, { pr, section }: RowData): RowParts {
  const author = person(pr.author, store.displayName(pr.author));
  const job = home.status.jobs.find((j) => j.pr === pr.id);
  if (pr.tab === "to-review" || sectionTab(section ?? undefined) === "review") {
    if (pr.review && REVIEW_RUNNING.includes(pr.review)) {
      return { leading: { kind: "avatar", person: author }, status: { kind: "agents", text: job?.phase ?? "Reviewing" },
               action: { kind: "reviewing", label: "Reviewing…" } };
    }
    if (pr.review === "ready") {
      const comments = home.findingCounts?.[pr.id];
      return { leading: { kind: "avatar", person: author },
               action: { kind: "comments", label: comments === undefined ? "Review Ready" : count(comments, "comment") } };
    }
    return { leading: { kind: "avatar", person: author }, action: { kind: "review", label: "Review" } };
  }
  if (section === null) {
    const entry = home.ci.find((c) => c.pr === pr.id);
    const fixing = entry?.phase !== undefined;
    const status: PRStatusLine = fixing && job ? { kind: "agents", text: job.phase }
      : { kind: "failed", text: entry?.failedChecks !== undefined ? `${count(entry.failedChecks, "check")} failed` : "Checks failed" };
    return { leading: { kind: "state", state: "failing" }, status,
             action: fixing ? { kind: "reviewing", label: "Fixing…" } : { kind: "fixci", label: "Fix CI" } };
  }
  if (section === "myFeedback") {
    const comments = store.detail(pr.id)?.respond?.items.length;
    const running = pr.respond !== undefined && !RESPOND_IDLE.includes(pr.respond);
    const status: PRStatusLine = running && job ? { kind: "agents", text: job.phase }
      : { kind: "changes", text: comments === undefined ? "Changes requested" : `Changes requested · ${count(comments, "comment")}` };
    return { leading: { kind: "state", state: "feedback" }, status,
             action: running ? { kind: "reviewing", label: "Responding…" } : { kind: "respond", label: "Respond" } };
  }
  if (section === "readyToMerge") {
    const approved = pr.approvals === undefined ? "Approved" : `Approved by ${pr.approvals}`;
    return { leading: { kind: "state", state: "ready" }, status: { kind: "approved", text: `${approved} · checks passing` },
             action: { kind: "merge", label: "Merge…" } };
  }
  // Waiting for Review: nada que hacer, el avatar del autor.
  return { leading: { kind: "avatar", person: author } };
}

/** Adónde va tocar una fila (PhoneApp.defaultRoute). */
export function defaultScreen(store: AppStore, id: string): PRScreenId | undefined {
  const info = store.prInfo(id);
  if (!info) return undefined;
  if (store.home.value?.ci.some((c) => c.pr === id)) return "fixci";
  switch (info.section) {
    case "toReview":
    case "updatedSinceMyReview":
    case "otherToReview":
      return "review";
    case "myFeedback":
      return "respond";
    case "readyToMerge":
      return "merge";
    default:
      return info.tab === "to-review" ? "review" : undefined;
  }
}

/** La píldora de la Mac (Home, Activity). */
export function macInfo(store: AppStore, ctx: Pick<AppContext, "locale">): MacInfo {
  const name = store.macName.value ?? "Your Mac";
  const now = store.now.value;
  const last = store.lastUpdated.value;
  if (store.isStale.value) {
    return { name, online: false, detail: last === null ? "Offline" : `Offline · last seen ${time(last, ctx.locale)}` };
  }
  if (last === null || now - last < 60_000) return { name, online: true, detail: "Connected · updated just now" };
  return { name, online: true, detail: `Connected · updated ${ago(last, now)}` };
}

/** La tarjeta de home:offline según el estado del enlace. */
export function offlineCard(link: LinkState, macName: string, lastUpdated: number | null, now: number,
                            ctx: Pick<AppContext, "locale">): OfflineCardVM | undefined {
  const cached = "You're seeing cached data, and actions are off";
  switch (link.kind) {
    case "macOffline": {
      const since = link.since ?? lastUpdated;
      const when = since === null ? "" : `Last connected ${dayAndTime(since, now, ctx.locale)}. `;
      return { title: `${macName} is offline or asleep`, message: `${when}${cached} until your Mac is back.` };
    }
    case "relayUnreachable":
      return { title: `Can't connect to ${macName}`,
               message: `There's a problem reaching the relay. ${cached} until the connection is back.` };
    case "relayRejected":
      return { title: `Can't connect to ${macName}`,
               message: "The relay server didn’t accept this iPhone. Check iPhone access in PRBar on your Mac." };
    case "replaced":
      return { title: "PRBar is open in another window", message: "Close it there to use it here." };
    case "incompatible":
      return { title: link.message.replace(/\.$/, ""), message: `${cached} until both are up to date.` };
    default:
      return undefined;
  }
}

export interface HomeModel {
  props(tab: HomeTab): HomeProps;
  badge: ReadonlySignal<number>;
  refreshing: ReadonlySignal<boolean>;
  collapsed: ReadonlySignal<ReadonlySet<string>>;
  refresh(): Promise<void>;
  retry(): void;
  open(id: string): void;
  action(id: string): Promise<void>;
  toggle(sectionId: string): void;
}

export function createHomeModel(ctx: AppContext): HomeModel {
  const { store } = ctx;
  const collapsed = signal<ReadonlySet<string>>(new Set(QUIET));
  const refreshing = signal(false);
  const retrying = signal(false);
  const badge = computed(() => tabCount(store.home.value, "review"));

  const go = (pr: string, screen: PRScreenId | undefined) => {
    const route: Route = screen ? { kind: "pr", pr, screen } : { kind: "pr", pr };
    ctx.nav.go(route);
  };

  const perform = async (command: Parameters<typeof ctx.runner.run>[0]) => {
    try {
      await ctx.runner.run(command);
    } catch (error) {
      if (error instanceof ActionFailure && error.error.kind !== "cancelled") ctx.ui.alert(error.message);
    }
  };

  const model: HomeModel = {
    badge,
    refreshing,
    collapsed,
    async refresh() {
      if (store.isStale.value) {
        model.retry();
        return;
      }
      if (refreshing.value) return;
      refreshing.value = true;
      try {
        await perform({ refresh: {} });
      } finally {
        refreshing.value = false;
      }
    },
    retry() {
      retrying.value = true;
      store.transport.retryNow();
      setTimeout(() => (retrying.value = false), 1500);
    },
    open(id) {
      go(id, defaultScreen(store, id));
    },
    async action(id) {
      if (store.isStale.value) return;
      const home = store.home.value;
      const pr = home?.prs.find((p) => p.id === id);
      if (!home || !pr) return;
      const section = homeSections(home, prTab(pr) ?? "review").find((s) => s.rows.some((r) => r.pr.id === id));
      const parts = rowParts(store, home, { pr, section: section?.id === CI_FAILING ? null : pr.section ?? null });
      switch (parts.action?.kind) {
        case "review":
          go(id, "review");
          await perform({ reviewStart: { pr: id, wait: false } });
          return;
        case "fixci":
          go(id, "fixci");
          await perform({ ciFix: { pr: id, wait: false } });
          return;
        case "merge":
          go(id, "merge");
          return;
        case "respond":
          go(id, "respond");
          return;
        default:
          go(id, defaultScreen(store, id));
      }
    },
    toggle(sectionId) {
      const next = new Set(collapsed.value);
      if (next.has(sectionId)) next.delete(sectionId);
      else next.add(sectionId);
      collapsed.value = next;
    },
    props(tab) {
      const home = store.home.value;
      const stale = store.isStale.value;
      const now = store.now.value;
      const sections: PRSectionVM[] = homeSections(home, tab).map((s) => ({
        id: s.id,
        title: s.title,
        count: s.rows.length,
        collapsed: collapsed.value.has(s.id),
        rows: home ? s.rows.map((r) => rowVM(store, home, r, now, stale)) : [],
      }));
      const mac = macInfo(store, ctx);
      const link = store.link.value;
      const offline = offlineCard(link, mac.name, store.lastUpdated.value, now, ctx);
      let banner: BannerVM | undefined;
      if (!offline && stale && (link.kind === "connecting" || link.kind === "disconnected")) {
        banner = { tone: "neutral", icon: "clock", text: `Connecting to ${mac.name}…` };
      }
      return {
        mac,
        title: tab === "review" ? "To Review" : "My PRs",
        sections,
        offline: offline ? { ...offline, retrying: retrying.value } : undefined,
        banner,
        refreshing: refreshing.value,
        onOpen: (id) => model.open(id),
        onAction: (id) => void model.action(id),
        onToggleSection: (id) => model.toggle(id),
        onFilter: () => {},
        onRetry: () => model.retry(),
      };
    },
  };
  return model;
}

function rowVM(store: AppStore, home: RemoteHome, data: RowData, now: number, disabled: boolean): PRRowVM {
  const { pr } = data;
  const parts = rowParts(store, home, data);
  const updated = parseDate(pr.updatedAt) ?? now;
  return {
    id: pr.id,
    title: pr.title,
    repo: repoName(pr.repo),
    number: pr.number,
    branch: pr.baseRef,
    age: age(updated, now),
    additions: pr.additions,
    deletions: pr.deletions,
    leading: parts.leading,
    status: parts.status,
    action: parts.action,
    disabled: disabled || undefined,
  };
}
