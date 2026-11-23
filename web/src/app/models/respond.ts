import { computed, signal, type ReadonlySignal } from "@preact/signals";
import { prTopic, type AppCommand, type RespondInfo } from "../../protocol/commands";
import type {
  ChangedFileVM, CheckLogLine, FailedCheckVM, FeedbackCommentVM, FixCIProps, ProgressVM, RespondBaseProps,
  RespondDiffProps, RespondProps, StageVM, StatusVM,
} from "../../ui/screens/types";
import type { AppContext, ConfirmRequest } from "../context";
import { parseUnifiedDiff, type DiffFile } from "../diff";
import { clock, count, duration, parseDate, person } from "../format";
import { needsConfirmation, perform, prHeader, showsFaceId, undoWithConfirmation } from "./common";

// respond, respond:fixci y respond:diff (RespondModel.swift): Claude contesta el feedback o arregla CI de un PR mío;
// después miro el diff y empujo (Face ID). Correr los tests también pide Face ID (ejecuta código en la Mac, H1).

export type RespondMode = "feedback" | "ciFix";

const RUNNING = ["queued", "preparing", "analyzing", "implementing", "pushing"];
const DONE = ["readyToPush", "done"];

export type RespondView =
  | { kind: "respond"; props: RespondProps }
  | { kind: "fixci"; props: FixCIProps }
  | { kind: "diff"; props: RespondDiffProps };

export interface RespondModel {
  mode: ReadonlySignal<RespondMode>;
  /** `screen`: la pantalla pedida (`diff` muestra los cambios; si no, respond o fixci según el modo). */
  view(screen: "main" | "diff"): RespondView;
  open(): () => void;
  start(): Promise<void>;
  implement(): Promise<void>;
  push(): Promise<void>;
  runTests(): Promise<void>;
  stop(): Promise<void>;
  undo(): Promise<void>;
  toggle(id: string, selected: boolean): Promise<void>;
  loadDiff(): Promise<void>;
}

/** Una línea del extracto de log: error, detalle o normal. */
export function logLine(text: string): CheckLogLine {
  if (/error|fail|✗|×|✕|panic|exception/i.test(text)) return { text, tone: "error" };
  if (/^\s+(at |→|-->|\|)|^\s{2,}/.test(text)) return { text, tone: "detail" };
  return { text, tone: "plain" };
}

/** `file`: el archivo que se tocó en Fix CI (llega en la ruta de respond:diff, que arma otro modelo). */
export function createRespondModel(ctx: AppContext, pr: string, fallback: RespondMode, file?: string): RespondModel {
  const { store } = ctx;
  const busy = signal(false);
  const startedAt = signal<number | null>(null);
  const diff = signal<{ files: DiffFile[]; truncated: boolean } | null>(null);
  const selectedFile = signal<string | null>(file ?? null);

  const respond = computed((): RespondInfo | undefined => store.details.value[pr]?.respond);
  const mode = computed((): RespondMode => respond.value?.mode ?? fallback);
  const phase = computed(() => respond.value?.phase);
  const isRunning = computed(() => (phase.value !== undefined && RUNNING.includes(phase.value)) || !!respond.value?.runningTests);
  const isDone = computed(() => phase.value !== undefined && DONE.includes(phase.value));
  const items = computed(() => respond.value?.items ?? []);
  const isReplyOnly = computed(() => mode.value === "feedback" && items.value.length > 0 && !items.value.some((i) => i.implement));
  const hasRun = computed(() => respond.value !== undefined && phase.value !== "none");

  const diffStatFiles = (): number | null => {
    const first = respond.value?.diffStat?.trim().split(" ")[0];
    return first && /^\d+$/.test(first) ? Number(first) : null;
  };

  const status = (): StatusVM => {
    const files = diffStatFiles();
    if (isDone.value && files !== null) {
      const tests = respond.value?.tests ? (respond.value.tests.passed ? "tests passing" : "tests failing") : "tests passing";
      return { kind: "passing", text: `${count(files, "file")} · ${tests}` };
    }
    if (mode.value === "ciFix") return { kind: "failed", text: `${count(respond.value?.ciChecks?.length ?? store.home.value?.ci.find((c) => c.pr === pr)?.failedChecks ?? 0, "check")} failed` };
    const reviewers = [...new Set(items.value.map((i) => i.reviewer))].sort().map((r) => store.displayName(r));
    return { kind: "changes", text: `Changes requested by ${reviewers.length ? reviewers.join(", ") : "a reviewer"}` };
  };

  const progress = (): ProgressVM | undefined => {
    if (!isRunning.value && !isDone.value) return undefined;
    const r = respond.value;
    const p = phase.value ?? "queued";
    const testing = !!r?.runningTests;
    const current = ["readyToPush", "pushing", "done"].includes(p) ? 3 : p === "implementing" ? (testing ? 2 : 1) : 0;
    const stages: StageVM[] = ["Analyzing", "Implementing", "Running tests"].map((label, index) => {
      const state = index < current ? "done" : index === current ? "current" : "pending";
      let detail: string | undefined;
      if (index === 1 && state === "current" && r?.currentFile) detail = `Editing ${r.currentFile}`;
      if (index === 2 && state !== "pending") detail = r?.testSummary ?? r?.tests?.outputTail;
      return { label, state, detail };
    });
    const start = parseDate(r?.startedAt) ?? startedAt.value;
    const fixing = mode.value === "feedback" ? count(items.value.filter((i) => i.implement).length, "comment")
      : count(r?.ciChecks?.length ?? 0, "check");
    return {
      title: isDone.value ? "Fixed · tests passing" : `Claude is fixing ${fixing}`,
      done: isDone.value,
      elapsed: start === null ? "" : clock((store.now.value - start) / 1000),
      stages,
    };
  };

  const primaryLabel = (): string => {
    if (mode.value === "feedback" && !isRunning.value && !isDone.value) return "Implement";
    if (isReplyOnly.value) return "Reply";
    if (respond.value?.pushBlockedByTests) return "Push Anyway";
    return mode.value === "feedback" ? "Push & Reply" : "Push";
  };

  /** Lo que manda el primario una vez implementado: responder, pushear o pushear igual. */
  const pushCommand = (): AppCommand => {
    if (isReplyOnly.value) return { respondReplyOnly: { pr, confirmed: true, wait: false } };
    if (respond.value?.pushBlockedByTests) return { respondPushAnyway: { pr, confirmed: true, wait: false } };
    return { respondPush: { pr, confirmed: true, wait: false } };
  };

  /** La pregunta antes de publicar sin Face ID (la de la Mac, `RespondPane.confirmPublish`). */
  const pushQuestion = (command: AppCommand): ConfirmRequest => {
    const r = respond.value;
    const commits = r?.commits.filter((c) => c.status === "committed" && c.sha).length ?? 0;
    const replies = r?.pushed ? r.pendingReplies : r?.replies ?? 0;
    const as = r?.account ? ` as @${r.account}` : "";
    const branch = r?.headRef ?? "the branch";
    if ("respondReplyOnly" in command || (r?.pushed && mode.value === "feedback")) {
      return { title: `Post ${count(replies, "reply", "replies")}?`, message: `They’ll be posted on GitHub${as}.`,
               confirmLabel: "Post", cancelLabel: "Cancel" };
    }
    if ("respondPushAnyway" in command) {
      return { title: "The tests failed", confirmLabel: "Push Anyway", cancelLabel: "Cancel", destructive: true,
               message: `${r?.tests?.command ? `“${r.tests.command}”` : "The tests"} failed in PRBar’s worktree. Push the fixes${mode.value === "feedback" ? " and post the replies" : ""} anyway?` };
    }
    if (mode.value === "ciFix") {
      return { title: `Push ${count(commits, "commit")} to ${branch}?`, confirmLabel: "Push", cancelLabel: "Cancel",
               message: `PRBar pushes${as} after checking that the failing checks still fail. No comment is posted.` };
    }
    return { title: `Push ${count(commits, "commit")} to ${branch} and post ${count(replies, "reply", "replies")}?`,
             message: `They’ll be posted on GitHub${as}.`, confirmLabel: "Push and Reply", cancelLabel: "Cancel" };
  };

  const base = (): RespondBaseProps => {
    const stale = store.isStale.value;
    const implementing = mode.value === "feedback" && !isRunning.value && !isDone.value;
    const canPush = !isRunning.value && isDone.value && !stale && !busy.value;
    const canRunTests = phase.value === "readyToPush" && !!respond.value?.testCommand && !isRunning.value && !stale && !busy.value;
    return {
      pr: prHeader(ctx, pr, respond.value?.title),
      status: status(),
      progress: progress(),
      running: isRunning.value,
      disabled: stale || busy.value,
      faceIdPending: ctx.runner.faceIdPending.value,
      start: hasRun.value ? undefined : {
        label: mode.value === "feedback" ? "Respond with Claude" : "Fix CI with Claude",
        busy: busy.value, disabled: stale, onClick: () => void model.start(),
      },
      primaryLabel: primaryLabel(),
      primaryFaceId: !implementing && showsFaceId(ctx, pushCommand()),
      testsFaceId: showsFaceId(ctx, { respondTest: { pr, wait: false } }),
      primaryDisabled: implementing ? stale || busy.value || items.value.length === 0 : !canPush,
      secondaryHidden: !isRunning.value && !isDone.value,
      onRunTests: canRunTests ? () => void model.runTests() : undefined,
      onBack: () => ctx.nav.back(),
      onChat: () => ctx.nav.go({ kind: "pr", pr, screen: "chat", chat: "respond" }),
      onStop: () => void model.stop(),
      onUndo: () => void model.undo(),
      onPrimary: () => void (implementing ? model.implement() : model.push()),
    };
  };

  const changedFiles = (): ChangedFileVM[] | undefined =>
    diff.value?.files.map((f) => ({ id: f.id, path: f.path, additions: f.additions, deletions: f.deletions }));

  const run = async (command: AppCommand) => {
    busy.value = true;
    try {
      await perform(ctx, command);
    } finally {
      busy.value = false;
    }
  };

  const model: RespondModel = {
    mode,
    view(screen) {
      if (screen === "diff") {
        const files = diff.value?.files ?? [];
        const replyItem = items.value.find((i) => i.reply && i.replyText);
        return {
          kind: "diff",
          props: {
            ...base(),
            files,
            selectedFileId: selectedFile.value ?? files[0]?.id ?? "",
            reply: replyItem ? { to: store.displayName(replyItem.reviewer), text: replyItem.replyText } : undefined,
            primaryLabel: primaryLabel(),
            onSelectFile: (id) => (selectedFile.value = id),
          },
        };
      }
      if (mode.value === "ciFix") {
        const r = respond.value;
        const failed = r?.ciChecks?.length;
        const checks: FailedCheckVM[] = (r?.ciChecks ?? []).map((c) => ({
          id: c.id,
          name: c.name,
          duration: c.durationSeconds === undefined ? "" : duration(c.durationSeconds),
          log: (c.logExcerpt ?? []).map(logLine),
        }));
        return {
          kind: "fixci",
          props: {
            ...base(),
            failedLabel: failed === undefined ? "" : r?.totalChecks !== undefined ? `${failed} of ${r.totalChecks}` : `${failed} failed`,
            checks,
            files: isDone.value ? changedFiles() : undefined,
            onOpenFile: (id) => {
              selectedFile.value = id;
              // respond:diff es otra pantalla con su propio modelo: el archivo va en la ruta.
              ctx.nav.go({ kind: "pr", pr, screen: "diff", file: id });
            },
          },
        };
      }
      const comments: FeedbackCommentVM[] = items.value.map((item) => ({
        id: item.id,
        author: person(item.reviewer, store.displayName(item.reviewer)),
        location: item.location,
        text: item.thread[0] ?? item.assessment,
        selected: item.implement,
      }));
      return {
        kind: "respond",
        props: {
          ...base(),
          comments,
          changesSummary: isDone.value ? respond.value?.diffStat : undefined,
          onToggleComment: (id, selected) => void model.toggle(id, selected),
          onOpenChanges: () => ctx.nav.go({ kind: "pr", pr, screen: "diff" }),
        },
      };
    },
    open() {
      const topic = prTopic(pr);
      store.retain(topic);
      return () => store.release(topic);
    },
    async start() {
      if (store.isStale.value || busy.value) return;
      startedAt.value = store.now.value;
      await run(mode.value === "feedback" ? { respondStart: { pr, wait: false } } : { ciFix: { pr, wait: false } });
    },
    async implement() {
      if (store.isStale.value || busy.value) return;
      startedAt.value ??= store.now.value;
      await run({ respondImplement: { pr, wait: false } });
    },
    async push() {
      if (store.isStale.value || busy.value) return;
      const command = pushCommand();
      // Sin `await` antes de mandarlo si hay Face ID: el aviso tiene que salir dentro del toque.
      if (needsConfirmation(ctx, command)) {
        busy.value = true;
        try {
          if (!(await ctx.ui.confirm(pushQuestion(command)))) return;
        } finally {
          busy.value = false;
        }
      }
      await run(command);
    },
    async runTests() {
      if (store.isStale.value || busy.value) return;
      await run({ respondTest: { pr, wait: false } });
    },
    async stop() {
      await run({ respondCancel: { pr } });
    },
    async undo() {
      busy.value = true;
      try {
        await undoWithConfirmation(ctx, pr);
      } finally {
        busy.value = false;
      }
    },
    async toggle(id, selected) {
      await perform(ctx, { respondSelect: { pr, items: [id], change: { implement: selected } } });
    },
    async loadDiff() {
      const result = await perform(ctx, { respondDiff: { pr } });
      if (!result) return;
      diff.value = { files: parseUnifiedDiff(result.diff ?? "", result.sensitiveChanges), truncated: result.truncated };
      if (selectedFile.value === null || !diff.value.files.some((f) => f.id === selectedFile.value)) {
        selectedFile.value = diff.value.files[0]?.id ?? null;
      }
    },
  };
  return model;
}
