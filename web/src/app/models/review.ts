import { computed, signal, type ReadonlySignal } from "@preact/signals";
import { prTopic, type AppCommand, type FindingInfo, type ReviewEvent } from "../../protocol/commands";
import type { EditProps, FindingVM, ReviewDecision, ReviewPostedProps, ReviewProps } from "../../ui/screens/types";
import type { AppContext } from "../context";
import { age, count, duration, lineOf, parseDate, person, shortRef, splitPRId } from "../format";
import { needsConfirmation, perform, prHeader, showsFaceId } from "./common";

// review (+ :menu, :faceid), edit y review:posted (ReviewModel.swift). Postear (cualquier decisión) pide Face ID.

const EVENTS: Record<ReviewDecision, ReviewEvent> = { comment: "COMMENT", request_changes: "REQUEST_CHANGES", approve: "APPROVE" };
const RUNNING = ["queued", "preparing", "reviewing", "filtering"];

export type ReviewView =
  | { kind: "review"; props: ReviewProps; edit?: EditProps | undefined }
  | { kind: "posted"; props: ReviewPostedProps };

export interface ReviewModel {
  view: ReadonlySignal<ReviewView>;
  open(): () => void;
  start(): Promise<void>;
  post(): Promise<void>;
  setIncluded(id: string, included: boolean): Promise<void>;
  saveEdit(): Promise<void>;
}

export function createReviewModel(ctx: AppContext, pr: string): ReviewModel {
  const { store } = ctx;
  const decision = signal<ReviewDecision>("comment");
  const menuOpen = signal(false);
  const posting = signal(false);
  const starting = signal(false);
  const overrides = signal<Record<string, boolean>>({});
  const editing = signal<{ id: string; text: string; saving: boolean } | null>(null);
  const posted = signal<{ decision: ReviewDecision; comments: number; url: string; mac: string } | null>(null);

  const publishCommand = (chosen: ReviewDecision): Extract<AppCommand, { reviewPublish: unknown }> =>
    ({ reviewPublish: { pr, event: EVENTS[chosen], withComments: true, allInBody: false, confirmed: true } });

  const review = computed(() => store.details.value[pr]?.review);
  const phase = computed(() => review.value?.phase ?? "none");
  const running = computed(() => RUNNING.includes(phase.value));
  const findings = computed((): FindingInfo[] => (review.value?.findings ?? []).filter((f) => !f.hiddenBy).map((f) => {
    const included = overrides.value[f.id];
    return included === undefined ? f : { ...f, included };
  }));

  const model: ReviewModel = {
    view: computed((): ReviewView => {
      const done = posted.value;
      if (done) {
        const verb = done.decision === "approve" ? "Approved" : done.decision === "request_changes" ? "Requested changes on" : "Commented on";
        return {
          kind: "posted",
          props: {
            decision: done.decision,
            message: `${verb} ${shortRef(pr)} with ${count(done.comments, "comment")}.`,
            inlineComments: done.comments,
            postedFrom: done.mac,
            onViewOnGitHub: () => ctx.ui.openURL(done.url),
            onDone: () => {
              posted.value = null;
              ctx.nav.back();
            },
          },
        };
      }
      const info = store.prInfo(pr);
      const now = store.minute.value;
      const stale = store.isStale.value;
      const r = review.value;
      const vms: FindingVM[] = findings.value.map((f) => ({
        id: f.id, severity: f.severity, location: f.location, title: f.title, text: f.body, included: f.included,
      }));
      const metaParts = [r?.detail, r?.usage?.durationSeconds ? duration(r.usage.durationSeconds) : undefined]
        .filter((p): p is string => !!p);
      const summaryText = running.value ? "Claude is reviewing this PR…" : r?.summary ?? "";
      const hasReview = r !== undefined && phase.value !== "none";
      const props: ReviewProps = {
        pr: {
          ...prHeader(ctx, pr, r?.title),
          author: person(info?.author ?? "", info ? store.displayName(info.author) : ""),
          age: info ? age(parseDate(info.updatedAt) ?? now, now) : "",
          additions: info?.additions ?? 0,
          deletions: info?.deletions ?? 0,
          head: info?.headRef ?? "",
          base: info?.baseRef ?? "",
          files: info?.changedFiles ?? 0,
        },
        summary: { text: summaryText, meta: metaParts.join(" · ") },
        findings: vms,
        decision: decision.value,
        menuOpen: menuOpen.value,
        faceIdPending: ctx.runner.faceIdPending.value,
        posting: posting.value,
        postFaceId: showsFaceId(ctx, publishCommand(decision.value)),
        disabled: stale || phase.value !== "ready" || posting.value,
        start: hasReview ? undefined : {
          label: "Review with Claude", busy: starting.value, disabled: stale, onClick: () => void model.start(),
        },
        onBack: () => ctx.nav.back(),
        onChat: () => ctx.nav.go({ kind: "pr", pr, screen: "chat", chat: "review" }),
        onMore: () => void more(),
        onToggleFinding: (id, included) => void model.setIncluded(id, included),
        onEditFinding: (id) => {
          const f = findings.value.find((x) => x.id === id);
          if (f) editing.value = { id, text: f.body, saving: false };
        },
        onOpenDecisionMenu: () => (menuOpen.value = true),
        onCloseDecisionMenu: () => (menuOpen.value = false),
        onSelectDecision: (d) => {
          decision.value = d;
          menuOpen.value = false;
        },
        onPost: () => void model.post(),
      };
      const edit = editing.value;
      const index = edit ? findings.value.findIndex((f) => f.id === edit.id) : -1;
      const finding = index >= 0 ? findings.value[index] : undefined;
      return {
        kind: "review",
        props,
        edit: edit && finding ? {
          subtitle: `Finding ${index + 1} of ${findings.value.length}`,
          severity: finding.severity,
          location: finding.location,
          text: edit.text,
          line: lineOf(finding.location) ?? 0,
          saving: edit.saving,
          onChange: (text) => (editing.value = { ...edit, text }),
          onSave: () => void model.saveEdit(),
          onDiscard: () => (editing.value = null),
        } : undefined,
      };
    }),
    open() {
      const topic = prTopic(pr);
      store.retain(topic);
      return () => store.release(topic);
    },
    async start() {
      if (starting.value || store.isStale.value) return;
      starting.value = true;
      try {
        await perform(ctx, { reviewStart: { pr, wait: false } });
      } finally {
        starting.value = false;
      }
    },
    async setIncluded(id, included) {
      overrides.value = { ...overrides.value, [id]: included };
      const ok = await perform(ctx, { reviewSetIncluded: { pr, findings: [id], all: false, included } });
      if (!ok) {
        const { [id]: _, ...rest } = overrides.value;
        overrides.value = rest;
      }
    },
    async saveEdit() {
      const edit = editing.value;
      if (!edit || edit.saving) return;
      editing.value = { ...edit, saving: true };
      const ok = await perform(ctx, { reviewEdit: { pr, finding: edit.id, body: edit.text } });
      editing.value = ok ? null : { ...edit, saving: false };
    },
    async post() {
      if (posting.value || store.isStale.value) return;
      const chosen = decision.value;
      const command = publishCommand(chosen);
      posting.value = true;
      try {
        // Sin `await` antes de `perform` si hay Face ID: el aviso tiene que salir dentro del toque.
        if (needsConfirmation(ctx, command) && !(await ctx.ui.confirm(publishQuestion(chosen)))) return;
        const result = await perform(ctx, command);
        if (result) {
          posted.value = { decision: chosen, comments: result.comments, url: result.url,
                           mac: store.macName.value ?? "your Mac" };
        }
      } finally {
        posting.value = false;
      }
    },
  };

  const publishQuestion = (chosen: ReviewDecision) => {
    const ref = shortRef(pr);
    const comments = findings.value.filter((f) => f.included).length;
    const title = chosen === "approve" ? `Approve ${ref}?` : chosen === "request_changes" ? `Request changes on ${ref}?`
      : `Post a review on ${ref}?`;
    const account = store.prInfo(pr)?.account;
    const parts = [comments > 0 ? `With ${count(comments, "inline comment")}.` : undefined,
                   account ? `It’ll be posted on GitHub as @${account}.` : "It’ll be posted on GitHub."];
    return { title, message: parts.filter(Boolean).join(" "), confirmLabel: "Post", cancelLabel: "Cancel" };
  };

  const more = async () => {
    type Item = "cancel" | "dismiss" | "github";
    const items: { id: Item; label: string; destructive?: boolean }[] = [];
    if (running.value) items.push({ id: "cancel", label: "Cancel Review", destructive: true });
    else if (review.value && phase.value !== "none") items.push({ id: "dismiss", label: "Dismiss" });
    const url = store.prInfo(pr)?.url ?? `https://github.com/${splitPRId(pr).repo}/pull/${splitPRId(pr).number}`;
    items.push({ id: "github", label: "Open in GitHub" });
    const choice = await ctx.ui.menu<Item>("More", items);
    if (choice === "github") ctx.ui.openURL(url);
    if (choice === "dismiss") await perform(ctx, { reviewDismiss: { pr } });
    if (choice === "cancel") {
      const ok = await ctx.ui.confirm({ title: "Cancel this review?", confirmLabel: "Cancel Review",
                                        cancelLabel: "Keep Running", destructive: true });
      if (ok) await perform(ctx, { reviewCancel: { pr } });
    }
  };

  return model;
}
