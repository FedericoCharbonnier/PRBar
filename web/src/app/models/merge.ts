import { computed, signal, type ReadonlySignal } from "@preact/signals";
import { prTopic, type AppCommand, type MergeInfo, type MergeMethod, type MergePreviewInfo } from "../../protocol/commands";
import type { MergedProps, MergeProps } from "../../ui/screens/types";
import type { AppContext } from "../context";
import { count, person, shortRef } from "../format";
import { needsConfirmation, perform, prHeader, showsFaceId } from "./common";

// merge (+ :faceid) y merge:merged (MergeModel.swift): la vista previa de la Mac, Face ID y `merge` con el head que se
// mostró (si el PR se movió, la Mac lo rechaza y se recarga).

const STATE_TITLE: Record<string, string> = {
  approved: "Approved", changesRequested: "Changes requested", commented: "Commented", dismissed: "Dismissed",
};

export type MergeView = { kind: "merge"; props: MergeProps } | { kind: "merged"; props: MergedProps };

export interface MergeModel {
  view: ReadonlySignal<MergeView>;
  open(): () => void;
  load(): Promise<void>;
  merge(): Promise<void>;
}

export function methodNote(method: MergeMethod, base: string, commits: number): string {
  switch (method) {
    case "squash":
      return `${count(commits, "commit")} become${commits === 1 ? "s" : ""} one commit on ${base}.`;
    case "merge":
      return `Adds a merge commit and keeps all ${count(commits, "commit")}.`;
    case "rebase":
      return `Replays the ${count(commits, "commit")} on top of ${base}.`;
  }
}

export function createMergeModel(ctx: AppContext, pr: string): MergeModel {
  const { store } = ctx;
  const preview = signal<MergePreviewInfo | null>(null);
  const method = signal<MergeMethod>("squash");
  const merging = signal(false);
  const merged = signal<MergeInfo | null>(null);
  const mergeCommand = (headOid: string): Extract<AppCommand, { merge: unknown }> =>
    ({ merge: { pr, method: method.value, confirmed: true, expectedHeadOid: headOid } });

  const model: MergeModel = {
    view: computed((): MergeView => {
      const p = preview.value;
      const base = p?.baseRef ?? store.prInfo(pr)?.baseRef ?? "main";
      const done = merged.value;
      if (done) {
        const verb = { squash: `was squashed into ${base}`, merge: `was merged into ${base}`, rebase: `was rebased onto ${base}` };
        const channel = store.details.value[pr]?.slackChannel;
        return {
          kind: "merged",
          props: {
            message: `${shortRef(pr)} ${verb[done.method]}.`,
            postedIn: channel ? `Posted in ${channel}` : undefined,
            onClose: () => ctx.nav.back(),
            onChat: () => ctx.nav.go({ kind: "pr", pr, screen: "chat", chat: "merge" }),
            onViewOnGitHub: () => ctx.ui.openURL(done.url),
            onDone: () => ctx.nav.back(),
          },
        };
      }
      const info = store.prInfo(pr);
      const detail = p?.detail;
      const checks = detail?.checks ?? [];
      const failed = checks.filter((c) => c.state === "failed").length;
      const runningChecks = checks.filter((c) => c.state === "running").length;
      const passing = checks.filter((c) => c.state === "passed").length;
      const commits = p?.commitCount ?? detail?.commitCount ?? 0;
      return {
        kind: "merge",
        props: {
          pr: {
            ...prHeader(ctx, pr, p?.title),
            head: p?.headRef ?? info?.headRef ?? "",
            base,
            additions: detail?.additions ?? info?.additions ?? 0,
            deletions: detail?.deletions ?? info?.deletions ?? 0,
          },
          description: detail?.body?.trim() || p?.problem || "",
          reviewers: (detail?.reviews ?? []).map((r) => ({
            person: person(r.author, store.displayName(r.author)),
            state: STATE_TITLE[r.state] ?? r.state,
            tone: r.state === "approved" ? "green" : r.state === "changesRequested" ? "orange" : "neutral",
          })),
          checks: !detail ? { text: "—", tone: "neutral" }
            : failed > 0 ? { text: `${failed} failing`, tone: "red" }
            : runningChecks > 0 ? { text: `${runningChecks} running`, tone: "neutral" }
            : { text: `${passing} passing`, tone: "green" },
          unresolved: detail && detail.unresolvedThreads > 0 ? `${detail.unresolvedThreads} unresolved` : "None",
          files: `${detail?.changedFiles ?? info?.changedFiles ?? 0} changed`,
          method: method.value,
          methodNotes: {
            squash: methodNote("squash", base, commits),
            merge: methodNote("merge", base, commits),
            rebase: methodNote("rebase", base, commits),
          },
          merging: merging.value,
          faceIdPending: ctx.runner.faceIdPending.value,
          mergeFaceId: showsFaceId(ctx, mergeCommand(p?.headOid ?? "")),
          disabled: store.isStale.value || !p || !!p.problem || merging.value,
          onBack: () => ctx.nav.back(),
          onChat: () => ctx.nav.go({ kind: "pr", pr, screen: "chat", chat: "merge" }),
          onFiles: () => {
            const url = p?.url ?? info?.url;
            if (url) ctx.ui.openURL(`${url}/files`);
          },
          onMethod: (m) => (method.value = m),
          onMerge: () => void model.merge(),
        },
      };
    }),
    open() {
      const topic = prTopic(pr);
      store.retain(topic);
      if (!preview.value) void model.load();
      return () => store.release(topic);
    },
    async load() {
      const result = await perform(ctx, { mergePreview: { pr } });
      if (!result) return;
      preview.value = result;
      method.value = result.method;
      if (result.problem) ctx.ui.alert(result.problem);
    },
    async merge() {
      const p = preview.value;
      if (!p || merging.value || store.isStale.value) return;
      const command = mergeCommand(p.headOid);
      merging.value = true;
      let reload = false;
      try {
        // Sin `await` antes de `perform` si hay Face ID: el aviso tiene que salir dentro del toque.
        if (needsConfirmation(ctx, command) && !(await ctx.ui.confirm({
          title: `Merge ${shortRef(pr)}?`,
          message: methodNote(method.value, p.baseRef, p.commitCount ?? p.detail?.commitCount ?? 0),
          confirmLabel: "Merge",
          cancelLabel: "Cancel",
        }))) return;
        const result = await perform(ctx, command, {
          onError: (error) => {
            // El head cambió (u otra cosa): se muestra lo que hay ahora.
            if (error.kind !== "cancelled") reload = true;
          },
        });
        if (result) merged.value = result;
      } finally {
        merging.value = false;
      }
      if (reload) await model.load();
    },
  };
  return model;
}
