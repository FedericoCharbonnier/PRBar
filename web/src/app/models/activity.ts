import { computed, type ReadonlySignal } from "@preact/signals";
import type { ActivityProps, RunningTaskVM, SpendSegmentVM, StatTileVM } from "../../ui/screens/types";
import type { AppContext } from "../context";
import { bytes, clock, money, parseDate, shortRef } from "../format";
import { perform } from "./common";
import { macInfo } from "./home";

// activity (ActivityModel.swift): carga de la Mac, trabajos corriendo con Stop y el costo de Claude del mes. El
// tópico se suscribe solo con la pantalla visible (la Mac lo recalcula cada 5 s mientras alguien escucha).

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                "November", "December"];

export interface ActivityModel {
  props: ReadonlySignal<ActivityProps>;
  open(): () => void;
  stop(id: string): Promise<void>;
}

/** "Reviewing api#317", "Fixing CI on web-app#488", "Responding on web-app#475", "Merging api#322". */
export function taskTitle(kind: string, pr: string, ciFailing: boolean): string {
  const ref = shortRef(pr);
  if (kind === "review") return `Reviewing ${ref}`;
  if (kind === "merge") return `Merging ${ref}`;
  return ciFailing ? `Fixing CI on ${ref}` : `Responding on ${ref}`;
}

export function createActivityModel(ctx: AppContext): ActivityModel {
  const { store } = ctx;
  const tasks = computed(() => {
    const activity = store.activity.value;
    const now = store.now.value;
    const ci = new Set(store.home.value?.ci.map((c) => c.pr) ?? []);
    if (activity?.running) {
      return activity.running.map((job) => {
        const parts = [job.phase];
        const start = parseDate(job.startedAt);
        if (start !== null) parts.push(clock((now - start) / 1000));
        if (job.costUSD !== undefined) parts.push(`~${money(job.costUSD)}`);
        return { id: `${job.kind}|${job.pr}`, kind: job.kind, pr: job.pr, title: taskTitle(job.kind, job.pr, ci.has(job.pr)),
                 sub: parts.join(" · ") };
      });
    }
    return (store.home.value?.status.jobs ?? []).map((job) => ({
      id: `${job.kind}|${job.pr}`, kind: job.kind, pr: job.pr, title: taskTitle(job.kind, job.pr, ci.has(job.pr)), sub: job.phase,
    }));
  });

  const model: ActivityModel = {
    props: computed((): ActivityProps => {
      const activity = store.activity.value;
      const stats: StatTileVM[] = [];
      if (activity) {
        const usage = activity.resources.usage;
        const system = activity.system;
        const memory = system?.memoryUsedBytes ?? usage.memoryBytes;
        const disk = system?.diskFreeBytes ?? activity.resources.disk.items.reduce((n, i) => n + i.bytes, 0);
        stats.push(
          { icon: "cpu", label: "CPU", value: `${Math.round(usage.cpuPercent)}%`, sub: system ? `${system.cores} cores` : "",
            fraction: Math.min(usage.cpuPercent / 100, 1), tone: "green" },
          { icon: "memorychip", label: "Memory", value: bytes(memory),
            sub: system ? `of ${bytes(system.memoryTotalBytes)}` : "",
            fraction: system ? system.memoryUsedBytes / Math.max(system.memoryTotalBytes, 1) : 0, tone: "orange" },
          { icon: "internaldrive", label: "Disk", value: bytes(disk),
            sub: system ? `free of ${bytes(system.diskTotalBytes).replace(" GB", "")}` : "",
            fraction: system ? 1 - system.diskFreeBytes / Math.max(system.diskTotalBytes, 1) : 0, tone: "accent" },
        );
      }
      const running: RunningTaskVM[] = tasks.value.map(({ id, title, sub }) => ({ id, title, sub }));
      const month = activity?.usage?.month;
      const segments: SpendSegmentVM[] = [];
      if (month) {
        const rows: [string, string, SpendSegmentVM["tone"], boolean][] = [
          ["review", "Reviews", "violet", false], ["respond", "Fixes", "accent", false], ["chat", "Chat", "neutral", true],
        ];
        for (const [key, label, tone, messages] of rows) {
          const usage = month.byKind[key];
          if (!usage) continue;
          segments.push({ label, count: messages ? `${usage.runs} msgs` : `${usage.runs}`, amount: money(usage.costUSD ?? 0),
                          value: usage.costUSD ?? 0, tone });
        }
      }
      const [, m] = (month?.month ?? "").split("-").map(Number);
      const caption = m !== undefined && m >= 1 && m <= 12 ? `estimated · ${MONTHS[m - 1]}` : "estimated";
      return {
        mac: macInfo(store, ctx),
        stats,
        running,
        month: { total: month?.usage.costUSD !== undefined ? money(month.usage.costUSD) : "—", caption, segments },
        onStop: (id) => void model.stop(id),
      };
    }),
    open() {
      store.retain("activity");
      return () => store.release("activity");
    },
    async stop(id) {
      const task = tasks.value.find((t) => t.id === id);
      if (!task || store.isStale.value) return;
      await perform(ctx, task.kind === "review" ? { reviewCancel: { pr: task.pr } } : { respondCancel: { pr: task.pr } });
    },
  };
  return model;
}
