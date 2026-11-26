import { effect } from "@preact/signals";
import { describe, expect, it } from "vitest";
import { createActivityModel } from "../../../src/app/models/activity";
import { createChatModel } from "../../../src/app/models/chat";
import { createHomeModel, homeSections, tabCount } from "../../../src/app/models/home";
import { createMergeModel, methodNote } from "../../../src/app/models/merge";
import { createRespondModel, logLine } from "../../../src/app/models/respond";
import { createReviewModel } from "../../../src/app/models/review";
import { stepElapsed } from "../../../src/app/format";
import { createSettingsModel, REQUIRE_FACE_ID_LABEL } from "../../../src/app/models/settings";
import { CommandError, RemoteError } from "../../../src/transport/types";
import { appFixture, flush, makeApp, NOW, sentNames } from "./helpers";

const fx = appFixture();
const topicJSON = (name: string) => JSON.parse(fx.topics.find((t) => t.topic === name)!.text) as Record<string, unknown>;
const respondInfo = () => (fx.commands.find((c) => c.name === "respondShow")!.response as { result: Record<string, unknown> }).result;

describe("home", () => {
  it("To Review y My PRs con las filas del diseño", () => {
    const app = makeApp();
    const home = createHomeModel(app);
    const review = home.props("review");
    expect(review.title).toBe("To Review");
    expect(review.mac).toEqual({ name: "Studio", online: true, detail: "Connected · updated just now" });
    expect(review.sections.map((s) => [s.id, s.title, s.count])).toEqual([["toReview", "To Review", 1]]);
    const row = review.sections[0]!.rows[0]!;
    expect(row).toMatchObject({ id: "acme/api#317", repo: "api", number: 317, branch: "main", age: "12 min",
                                action: { kind: "comments", label: "2 comments" } });
    expect(row.leading).toMatchObject({ kind: "avatar", person: { name: "Tomás Ruiz", initials: "TR" } });
    const mine = home.props("mine");
    expect(mine.sections.map((s) => [s.title, s.count, s.collapsed])).toEqual([["Ready to Merge", 1, false], ["CI Failing", 1, false]]);
    expect(mine.sections[0]!.rows[0]).toMatchObject({ leading: { kind: "state", state: "ready" },
      status: { kind: "approved", text: "Approved by 2 · checks passing" }, action: { kind: "merge", label: "Merge…" } });
    expect(mine.sections[1]!.rows[0]).toMatchObject({ leading: { kind: "state", state: "failing" },
      status: { kind: "failed", text: "2 checks failed" }, action: { kind: "fixci", label: "Fix CI" } });
    expect(home.badge.value).toBe(1);
    expect(tabCount(app.store.home.value, "mine")).toBe(2);
  });

  it("secciones silenciosas colapsadas y toggle", () => {
    const app = makeApp();
    const data = topicJSON("home");
    (data.prs as Record<string, unknown>[]).push({ ...(data.prs as Record<string, unknown>[])[0], id: "acme/api#400", number: 400,
                                                  section: "otherToReview", review: undefined });
    app.transport.setTopic("home", data);
    const home = createHomeModel(app);
    const other = home.props("review").sections.find((s) => s.id === "otherToReview")!;
    expect(other.collapsed).toBe(true);
    expect(home.badge.value).toBe(1);
    home.toggle("otherToReview");
    expect(home.props("review").sections.find((s) => s.id === "otherToReview")!.collapsed).toBe(false);
    expect(homeSections(null, "review")).toEqual([]);
  });

  it("abrir una fila y las acciones mandan lo de la Mac", async () => {
    const app = makeApp();
    const home = createHomeModel(app);
    home.open("acme/api#322");
    expect(app.nav.last).toEqual({ kind: "pr", pr: "acme/api#322", screen: "merge" });
    home.open("acme/web-app#488");
    expect(app.nav.last).toEqual({ kind: "pr", pr: "acme/web-app#488", screen: "fixci" });
    const data = topicJSON("home");
    data.ci = [];
    app.transport.setTopic("home", data);
    home.open("acme/web-app#488");
    expect(app.ui.opened).toEqual(["https://github.com/acme/web-app/pull/488"]);
    app.transport.setTopic("home", topicJSON("home"));
    await home.action("acme/web-app#488");
    expect(sentNames(app)).toEqual(["ciFix"]);
    await home.refresh();
    expect(sentNames(app)).toEqual(["ciFix", "refresh"]);
    expect(home.refreshing.value).toBe(false);
  });

  it("home:offline: en gris, tarjeta de la Mac dormida y nada se manda", async () => {
    const app = makeApp();
    const since = Date.parse("2026-11-20T08:12:00Z");
    app.transport.setState({ kind: "macOffline", since });
    await flush();
    const home = createHomeModel(app);
    const props = home.props("review");
    expect(props.mac.online).toBe(false);
    expect(props.mac.detail).toMatch(/^Offline · last seen /);
    expect(props.offline).toMatchObject({
      title: "Studio is offline or asleep",
      message: "Last connected today at 8:12 AM. You're seeing cached data, and actions are off until your Mac is back.",
    });
    expect(props.sections[0]!.rows[0]!.disabled).toBe(true);
    await home.action("acme/api#317");
    await home.refresh();
    expect(app.transport.sent).toHaveLength(0);
  });

  it("los otros estados del enlace", () => {
    const app = makeApp();
    const home = createHomeModel(app);
    const card = (state: Parameters<typeof app.transport.setState>[0]) => {
      app.transport.setState(state);
      return home.props("review").offline;
    };
    expect(card({ kind: "relayUnreachable", retryAt: null })?.title).toBe("Can't connect to Studio");
    expect(card({ kind: "relayRejected", code: 4403 })?.message).toContain("didn’t accept this iPhone");
    expect(card({ kind: "replaced" })?.title).toBe("PRBar is open in another window");
    expect(card({ kind: "incompatible", reason: "updateMac", message: "Update PRBar on your Mac." })?.title).toBe("Update PRBar on your Mac");
    app.transport.setState({ kind: "connecting" });
    expect(home.props("review").banner?.text).toBe("Connecting to Studio…");
  });
});

describe("review", () => {
  it("muestra el review de la Mac y postea un Comment con Face ID", async () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    const close = model.open();
    expect(app.transport.topics).toEqual(["home", "pr:acme/api#317"]);
    const view = model.view.value;
    if (view.kind !== "review") throw new Error("review");
    expect(view.props.pr).toMatchObject({ repoFull: "acme/api", number: 317, files: 5, head: "feature/317", base: "main" });
    expect(view.props.summary.text).toBe("Sessions refresh in the background.");
    expect(view.props.summary.meta).toBe("2 agents");
    expect(view.props.findings.map((f) => f.included)).toEqual([true, true, false]);
    expect(view.props.start).toBeUndefined();
    expect(view.props.disabled).toBe(false);
    await model.post();
    expect(app.transport.sent.at(-1)).toEqual({
      command: { reviewPublish: { pr: "acme/api#317", event: "COMMENT", withComments: true, allInBody: false, confirmed: true } },
      presence: true,
    });
    expect(app.ui.confirms).toEqual([]);
    const posted = model.view.value;
    expect(posted.kind).toBe("posted");
    if (posted.kind === "posted") {
      expect(posted.props.message).toBe("Commented on api#317 with 3 comments.");
      expect(posted.props.postedFrom).toBe("Studio");
      posted.props.onViewOnGitHub();
      expect(app.ui.opened).toEqual(["https://github.com/acme/api/pull/317"]);
      posted.props.onDone();
      expect(app.nav.backs).toBe(1);
    }
    close();
    expect(app.transport.topics).toEqual(["home"]);
  });

  it("Approve pide Face ID; cancelado no manda nada ni avisa", async () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    const view = model.view.value;
    if (view.kind !== "review") throw new Error("review");
    view.props.onOpenDecisionMenu();
    expect((model.view.value as { props: { menuOpen: boolean } }).props.menuOpen).toBe(true);
    view.props.onSelectDecision("approve");
    app.presence.mode = "cancel";
    await model.post();
    expect(app.transport.sent).toHaveLength(0);
    expect(app.ui.alerts).toEqual([]);
    expect(model.view.value.kind).toBe("review");
    app.presence.mode = "sign";
    await model.post();
    expect(app.transport.sent.at(-1)).toMatchObject({ command: { reviewPublish: { event: "APPROVE" } }, presence: true });
    expect(app.signed).toHaveLength(1);
  });

  it("incluir y editar hallazgos; errores al banner", async () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    model.open();
    await model.setIncluded("f3", true);
    expect(app.transport.sent.at(-1)!.command).toEqual({ reviewSetIncluded: { pr: "acme/api#317", findings: ["f3"], all: false, included: true } });
    const view = model.view.value as { props: { findings: { included: boolean }[]; onEditFinding(id: string): void } };
    expect(view.props.findings[2]!.included).toBe(true);
    view.props.onEditFinding("f2");
    const edit = (model.view.value as { edit?: { subtitle: string; line: number; text: string; onChange(t: string): void } }).edit!;
    expect(edit.subtitle).toBe("Finding 2 of 3");
    expect(edit.line).toBe(81);
    edit.onChange("Shorter.");
    await model.saveEdit();
    expect(app.transport.sent.at(-1)!.command).toEqual({ reviewEdit: { pr: "acme/api#317", finding: "f2", body: "Shorter." } });
    expect((model.view.value as { edit?: unknown }).edit).toBeUndefined();
    app.transport.respond("reviewSetIncluded", () => new CommandError({ code: "invalidState", message: "The review changed." }));
    await model.setIncluded("f1", false);
    expect(app.ui.alerts).toEqual(["The review changed."]);
    expect((model.view.value as { props: { findings: { included: boolean }[] } }).props.findings[0]!.included).toBe(true);
  });

  it("sin review: Review with Claude; More con Cancel/Dismiss", async () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#999");
    const view = model.view.value as { props: { start?: { label: string; onClick(): void } } };
    expect(view.props.start?.label).toBe("Review with Claude");
    await model.start();
    expect(app.transport.sent.at(-1)!.command).toEqual({ reviewStart: { pr: "acme/api#999", wait: false } });
    const running = topicJSON("pr:acme/api#317");
    (running.review as Record<string, unknown>).phase = "reviewing";
    app.transport.setTopic("pr:acme/api#317", running);
    const other = createReviewModel(app, "acme/api#317");
    other.open();
    app.ui.menuAnswer = "cancel";
    (other.view.value as { props: { onMore(): void } }).props.onMore();
    await flush();
    expect(app.ui.menus[0]!.items.map((i) => i.label)).toEqual(["Cancel Review", "Open in GitHub"]);
    expect(app.ui.confirms[0]).toMatchObject({ title: "Cancel this review?", cancelLabel: "Keep Running" });
    expect(app.transport.sent.at(-1)!.command).toEqual({ reviewCancel: { pr: "acme/api#317" } });
  });

  it("con memoria: anteriores, recomendación preseleccionada y la elección manual gana", () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    model.open();
    const data = topicJSON("pr:acme/api#317");
    data.review = {
      ...(data.review as Record<string, unknown>),
      reviewedSince: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d",
      previous: [
        { id: "P1", location: "src/auth/session.ts:80", text: "Validate it.", status: "notFixed", note: "Still there.",
          github: "open", outdated: false },
        { id: "P2", location: "src/auth/session.ts:12", text: "Rename.", status: "fixed", note: "Done.", github: "resolved",
          outdated: true },
      ],
      recommendedAction: { event: "REQUEST_CHANGES", reason: "1 previous comment fixed, 1 not fixed: src/auth/session.ts:80" },
    };
    app.transport.setTopic("pr:acme/api#317", data);
    let view = model.view.value;
    if (view.kind !== "review") throw new Error("review");
    expect(view.props.decision).toBe("request_changes");
    expect(view.props.recommendation).toEqual({ label: "Request Changes",
                                                reason: "1 previous comment fixed, 1 not fixed: src/auth/session.ts:80" });
    expect(view.props.previous?.header).toBe("Reviewed before at 1a2b3c4 · 1 fixed · 1 pending");
    expect(view.props.previous?.comments.map((c) => [c.id, c.statusLabel, c.github]))
      .toEqual([["P1", "Not fixed", "open"], ["P2", "Fixed", "resolved · outdated"]]);
    view.props.onSelectDecision("approve");
    data.review = { ...(data.review as Record<string, unknown>), recommendedAction: { event: "COMMENT", reason: "x" } };
    app.transport.setTopic("pr:acme/api#317", data);
    view = model.view.value;
    if (view.kind !== "review") throw new Error("review");
    expect(view.props.decision).toBe("approve");
  });

  it("mientras corre: el paso de la Mac con su tiempo debajo de la fase; sin activity (una Mac vieja), nada", () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    model.open();
    const data = topicJSON("pr:acme/api#317");
    data.review = { ...(data.review as Record<string, unknown>), phase: "reviewing",
                    activity: { kind: "claude", text: "Reading src/shop/tax.py", startedAt: new Date(NOW - 12_000).toISOString() } };
    app.transport.setTopic("pr:acme/api#317", data);
    let view = model.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    expect(view.props.summary.activity).toBe("Reading src/shop/tax.py · 12 s");
    data.review = { ...(data.review as Record<string, unknown>), activity: undefined };
    app.transport.setTopic("pr:acme/api#317", data);
    view = model.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    expect(view.props.summary.activity).toBeUndefined();
  });
});

describe("review fallido", () => {
  it("muestra el motivo y Try Again vuelve a pedir el review", async () => {
    const app = makeApp();
    const failed = topicJSON("pr:acme/api#317");
    failed.review = { ...(failed.review as Record<string, unknown>), phase: "failed", detail: "claude exited with code 1.",
                      findings: [], summary: undefined };
    app.transport.setTopic("pr:acme/api#317", failed);
    const model = createReviewModel(app, "acme/api#317");
    model.open();
    const view = model.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    expect(view.props.error).toBe("claude exited with code 1.");
    expect(view.props.start?.label).toBe("Try Again");
    view.props.start!.onClick();
    await flush();
    expect(app.transport.sent.at(-1)!.command).toEqual({ reviewStart: { pr: "acme/api#317", wait: false } });
  });
});

describe("respond y fix CI", () => {
  const setRespond = (app: ReturnType<typeof makeApp>, pr: string, patch: Record<string, unknown>) => {
    app.transport.setTopic(`pr:${pr}`, { respond: { ...respondInfo(), pr, ...patch } });
  };

  it("mientras corre: la etapa actual muestra el paso de la Mac con su tiempo (en lugar del archivo)", () => {
    const app = makeApp();
    setRespond(app, "acme/web-app#488", {
      phase: "implementing", currentFile: "src/old.ts",
      activity: { kind: "prbar", text: "Committing…", startedAt: new Date(NOW - 125_000).toISOString() },
    });
    const model = createRespondModel(app, "acme/web-app#488", "feedback");
    model.open();
    const view = model.view("main");
    const stages = (view.props as { progress?: { stages: { state: string; detail?: string }[] } }).progress?.stages ?? [];
    expect(stages.find((s) => s.state === "current")?.detail).toBe("Committing… · 2 min 5 s");
  });

  it("fix CI listo: checks, archivos, push con Face ID", async () => {
    const app = makeApp();
    setRespond(app, "acme/web-app#488", { phase: "readyToPush", totalChecks: 9, testCommand: "npm test" });
    const model = createRespondModel(app, "acme/web-app#488", "feedback");
    model.open();
    await model.loadDiff();
    const view = model.view("main");
    if (view.kind !== "fixci") throw new Error(view.kind);
    expect(view.props.status).toEqual({ kind: "passing", text: "1 file · tests passing" });
    expect(view.props.failedLabel).toBe("1 of 9");
    expect(view.props.checks[0]).toEqual({ id: "c1", name: "test (ubuntu-latest)", duration: "1m 24s",
      log: [{ text: "FAIL src/jobs/report.test.ts", tone: "error" }, { text: "Expected 2, got 3", tone: "plain" }] });
    expect(view.props.files).toEqual([{ id: "src/jobs/report.test.ts", path: "src/jobs/report.test.ts", additions: 1, deletions: 1 }]);
    expect(view.props.progress?.title).toBe("Fixed · tests passing");
    expect(view.props.primaryLabel).toBe("Push");
    expect(view.props.primaryDisabled).toBe(false);
    expect(view.props.onRunTests).toBeDefined();
    await model.runTests();
    expect(app.transport.sent.at(-1)).toEqual({ command: { respondTest: { pr: "acme/web-app#488", wait: false } }, presence: true });
    await model.push();
    expect(app.transport.sent.at(-1)).toEqual({ command: { respondPush: { pr: "acme/web-app#488", confirmed: true, wait: false, mode: "ciFix" } }, presence: true });
    expect(app.signed).toHaveLength(2);
    const diff = model.view("diff");
    if (diff.kind !== "diff") throw new Error(diff.kind);
    expect(diff.props.files[0]!.lines.map((l) => l.kind)).toEqual(["hunk", "del", "add"]);
  });

  it("Resolve Conflicts: se ve con su nombre y el push es desde la Mac", async () => {
    const app = makeApp();
    const pr = "acme/web-app#488";
    setRespond(app, pr, { phase: "readyToPush", mode: "conflicts", ciChecks: undefined });
    const model = createRespondModel(app, pr, "feedback");
    model.open();
    const view = model.view("main");
    expect(view.props.title).toBe("Resolve Conflicts");
    expect(view.props.primaryLabel).toBe("Push from your Mac");
    expect(view.props.primaryDisabled).toBe(true);
    expect(view.props.primaryFaceId).toBe(false);
    expect(view.props.start).toBeUndefined();
    const sent = app.transport.sent.length;
    await model.push();
    expect(app.transport.sent.length).toBe(sent);
  });

  it("fix CI frenado porque los checks pasan ahora: banner y Push Anyway (ciFix) con Face ID", async () => {
    const app = makeApp();
    const pr = "acme/web-app#488";
    const reason = "The checks that failed (test) pass now on 9f3c2a1, so PRBar didn’t push.";
    setRespond(app, pr, { phase: "readyToPush", pushBlockedByCI: reason });
    const model = createRespondModel(app, pr, "ciFix");
    model.open();
    const view = model.view("main");
    if (view.kind !== "fixci") throw new Error(view.kind);
    expect(view.props.banner).toEqual({ tone: "orange", icon: "checkmark.circle", text: reason });
    expect(view.props).toMatchObject({ primaryLabel: "Push Anyway", primaryFaceId: true, primaryDisabled: false });
    view.props.onPrimary();
    expect(app.signed).toHaveLength(1);
    await flush();
    expect(app.transport.sent.at(-1)).toEqual({
      command: { respondPushAnyway: { pr, confirmed: true, wait: false, mode: "ciFix" } }, presence: true,
    });
    expect(app.ui.confirms).toEqual([]);

    // Sin Face ID, pregunta lo mismo que la Mac antes de mandarlo.
    app.transport.setPresencePolicy({ requirePresence: false, gated: app.transport.presencePolicy.gated });
    app.ui.confirmAnswer = false;
    await model.push();
    expect(app.ui.confirms[0]).toMatchObject({ title: "The CI passes now", message: `${reason} Push Claude’s fix anyway?`,
                                               confirmLabel: "Push Anyway" });
    expect(app.transport.sent).toHaveLength(1);
  });

  it("fix CI: tocar un archivo abre respond:diff en ese archivo (no en el primero)", async () => {
    const app = makeApp();
    setRespond(app, "acme/web-app#488", { phase: "readyToPush" });
    const twoFiles = [
      "diff --git a/src/a.ts b/src/a.ts", "--- a/src/a.ts", "+++ b/src/a.ts", "@@ -1 +1 @@", "-a", "+b",
      "diff --git a/src/b.ts b/src/b.ts", "--- a/src/b.ts", "+++ b/src/b.ts", "@@ -1 +1 @@", "-c", "+d", "",
    ].join("\n");
    app.transport.respond("respondDiff", () => ({ diff: twoFiles, truncated: false }));
    const fixci = createRespondModel(app, "acme/web-app#488", "ciFix");
    await fixci.loadDiff();
    const main = fixci.view("main");
    if (main.kind !== "fixci") throw new Error(main.kind);
    main.props.onOpenFile("src/b.ts");
    const route = app.nav.last;
    expect(route).toEqual({ kind: "pr", pr: "acme/web-app#488", screen: "diff", file: "src/b.ts" });
    // La pantalla de diff arma su propio modelo con lo que trae la ruta.
    if (route?.kind !== "pr") throw new Error("route");
    const diffModel = createRespondModel(app, "acme/web-app#488", "ciFix", route.file);
    await diffModel.loadDiff();
    const diff = diffModel.view("diff");
    if (diff.kind !== "diff") throw new Error(diff.kind);
    expect(diff.props.selectedFileId).toBe("src/b.ts");
  });

  it("feedback: Respond with Claude, Implement, Reply y Push Anyway", async () => {
    const app = makeApp();
    const model = createRespondModel(app, "acme/web-app#475", "feedback");
    expect(model.view("main").props.start?.label).toBe("Respond with Claude");
    await model.start();
    expect(app.transport.sent.at(-1)!.command).toEqual({ respondStart: { pr: "acme/web-app#475", wait: false } });
    setRespond(app, "acme/web-app#475", { phase: "ready", mode: undefined, ciChecks: undefined });
    let view = model.view("main");
    expect(view.kind).toBe("respond");
    expect(view.props).toMatchObject({ primaryLabel: "Implement", primaryFaceId: false, secondaryHidden: true });
    view.props.onPrimary();
    await flush();
    expect(app.transport.sent.at(-1)).toEqual({ command: { respondImplement: { pr: "acme/web-app#475", wait: false } }, presence: false });
    setRespond(app, "acme/web-app#475", { phase: "implementing", mode: undefined, ciChecks: undefined, currentFile: "src/a.ts",
                                          startedAt: "2026-11-20T12:48:00Z" });
    view = model.view("main");
    expect(view.props.running).toBe(true);
    expect(view.props.progress).toMatchObject({ title: "Claude is fixing 1 comment", elapsed: "2:00" });
    expect(view.props.progress!.stages[1]).toEqual({ label: "Implementing", state: "current", detail: "Editing src/a.ts" });
    view.props.onStop();
    await flush();
    expect(app.transport.sent.at(-1)!.command).toEqual({ respondCancel: { pr: "acme/web-app#475" } });
    const items = (respondInfo().items as Record<string, unknown>[]).map((i) => ({ ...i, implement: false }));
    setRespond(app, "acme/web-app#475", { phase: "readyToPush", mode: undefined, ciChecks: undefined, items });
    expect(model.view("main").props).toMatchObject({ primaryLabel: "Reply", primaryFaceId: true });
    await model.push();
    expect(app.transport.sent.at(-1)).toEqual({ command: { respondReplyOnly: { pr: "acme/web-app#475", confirmed: true, wait: false } }, presence: true });
    setRespond(app, "acme/web-app#475", { phase: "readyToPush", mode: undefined, ciChecks: undefined, pushBlockedByTests: true });
    expect(model.view("main").props.primaryLabel).toBe("Push Anyway");
    await model.push();
    expect(app.transport.sent.at(-1)).toMatchObject({ command: { respondPushAnyway: {} }, presence: true });
  });

  it("Undo pide confirmar lo que pregunta la Mac", async () => {
    const app = makeApp();
    let calls = 0;
    app.transport.respond("chatUndo", (command) => {
      calls++;
      return "chatUndo" in command && command.chatUndo.confirmed ? (fx.commands.find((c) => c.name === "chatUndo")!.response as { result: never }).result
        : new CommandError({ code: "confirmationRequired", message: "Undo will also discard your manual edits since then." });
    });
    const model = createRespondModel(app, "acme/web-app#488", "ciFix");
    await model.undo();
    expect(calls).toBe(2);
    expect(app.ui.confirms[0]).toMatchObject({ title: "Undo Claude’s changes?", message: "Undo will also discard your manual edits since then." });
    expect(app.ui.alerts).toEqual([]);
    app.ui.confirmAnswer = false;
    await model.undo();
    expect(calls).toBe(3);
  });

  it("líneas de log", () => {
    expect(logLine("Error: boom").tone).toBe("error");
    expect(logLine("    at foo (a.ts:1)").tone).toBe("detail");
    expect(logLine("ok").tone).toBe("plain");
  });
});

describe("merge", () => {
  it("vista previa, Face ID y merged", async () => {
    const app = makeApp();
    const model = createMergeModel(app, "acme/api#322");
    model.open();
    await flush();
    let view = model.view.value;
    if (view.kind !== "merge") throw new Error(view.kind);
    expect(view.props.pr).toMatchObject({ title: "Make payment retries idempotent", head: "feature/322", base: "main" });
    expect(view.props.methodNotes.squash).toBe("3 commits become one commit on main.");
    expect(view.props.disabled).toBe(false);
    view.props.onMethod("rebase");
    view.props.onMethod("squash");
    await model.merge();
    expect(app.transport.sent.at(-1)).toEqual({
      command: { merge: { pr: "acme/api#322", method: "squash", confirmed: true, expectedHeadOid: "9f3c2a1" } }, presence: true,
    });
    view = model.view.value;
    if (view.kind !== "merged") throw new Error(view.kind);
    expect(view.props.message).toBe("api#322 was squashed into main.");
    expect(view.props.postedIn).toBe("Posted in #api-reviews");
  });

  it("Face ID cancelado se queda; un error recarga la vista previa", async () => {
    const app = makeApp();
    const model = createMergeModel(app, "acme/api#322");
    await model.load();
    app.presence.mode = "cancel";
    await model.merge();
    expect(sentNames(app)).toEqual(["mergePreview"]);
    expect(model.view.value.kind).toBe("merge");
    app.presence.mode = "sign";
    app.transport.respond("merge", () => new CommandError({ code: "invalidState", message: "The PR changed. Check it again." }));
    await model.merge();
    expect(app.ui.alerts).toEqual(["The PR changed. Check it again."]);
    expect(sentNames(app)).toEqual(["mergePreview", "merge", "mergePreview"]);
    expect(methodNote("merge", "main", 1)).toBe("Adds a merge commit and keeps all 1 commit.");
  });
});

describe("chat", () => {
  it("chatShow al abrir y el texto en streaming", async () => {
    const app = makeApp();
    const model = createChatModel(app, "acme/api#317", "review");
    const close = model.open();
    await flush();
    expect(model.props.value.context).toBe("api#317 · Review");
    expect(model.props.value.items.map((i) => i.kind)).toEqual(["mine", "claude"]);
    expect(model.props.value.timestamp).toBe("Today 12:38 PM");
    model.props.value.onDraft("  Anything else worth flagging?  ");
    await model.send();
    expect(app.transport.sent.at(-1)!.command).toEqual({ chatSend: { pr: "acme/api#317", message: "Anything else worth flagging?" } });
    expect(model.props.value.draft).toBe("");
    expect(model.props.value.typing).toBe(false);
    // Un chat que sigue en la Mac.
    app.transport.emitChatDelta("acme/api#317", "From the Mac");
    expect(model.props.value.items.at(-1)).toMatchObject({ kind: "claude", text: "From the Mac" });
    close();
    app.transport.emitChatDelta("acme/api#317", " more");
    expect(model.props.value.items.at(-1)).toMatchObject({ text: "From the Mac" });
  });

  it("Send es Stop mientras Claude contesta", async () => {
    const app = makeApp();
    const model = createChatModel(app, "acme/api#317", "review");
    model.open();
    await flush();
    expect(model.props.value.running).toBe(false);
    app.transport.respond("chatSend", () => (fx.commands.find((c) => c.name === "chatShow")!.response as { result: never }).result);
    model.props.value.onDraft("Why?");
    const sending = model.send();
    expect(model.props.value).toMatchObject({ running: true, disabled: true });
    model.props.value.onStop!();
    await sending;
    await flush();
    expect(sentNames(app)).toContain("chatStop");
    expect(app.transport.sent.find((s) => "chatStop" in s.command)!.command).toEqual({ chatStop: { pr: "acme/api#317" } });
    expect(model.props.value.running).toBe(false);
  });

  it("si el mensaje no llegó a la Mac, vuelve al cuadro y su burbuja se va", async () => {
    const app = makeApp();
    const model = createChatModel(app, "acme/api#317", "review");
    model.open();
    await flush();
    const before = model.props.value.items.length;
    app.transport.respond("chatSend", () => new CommandError({ code: "invalidState", message: "Claude is still answering." }));
    model.props.value.onDraft("Why?");
    await model.send();
    await flush();
    expect(app.ui.alerts).toEqual(["Claude is still answering."]);
    expect(model.props.value.items).toHaveLength(before);
    expect(model.props.value.draft).toBe("Why?");
    expect(model.props.value.running).toBe(false);
  });

  it("si no contestó a tiempo pero el mensaje llegó, queda lo que tiene la Mac", async () => {
    const app = makeApp();
    const model = createChatModel(app, "acme/api#317", "review");
    model.open();
    await flush();
    const shown = (fx.commands.find((c) => c.name === "chatShow")!.response as { result: { messages: { id: string; role: string; text: string }[] } }).result;
    app.transport.respond("chatSend", () => new RemoteError("timeout"));
    app.transport.respond("chatShow", () => ({ ...shown, messages: [...shown.messages,
      { ...shown.messages[0]!, id: "new-1", role: "user", text: "Why?" }] }) as never);
    model.props.value.onDraft("Why?");
    await model.send();
    await flush();
    expect(model.props.value.items.at(-1)).toMatchObject({ kind: "mine", text: "Why?" });
    expect(model.props.value.draft).toBe("");
  });

  it("chat:merge es solo lectura", () => {
    const app = makeApp();
    const model = createChatModel(app, "acme/api#322", "merge");
    expect(model.props.value).toMatchObject({ readOnly: true, placeholder: "Ask about this PR", context: "api#322 · Merge" });
  });
});

describe("activity", () => {
  it("recursos, trabajos con Stop y costo del mes", async () => {
    const app = makeApp();
    const model = createActivityModel(app);
    const close = model.open();
    expect(app.transport.topics).toEqual(["activity", "home"].sort((a, b) => (a === "home" ? -1 : b === "home" ? 1 : 0)));
    const props = model.props.value;
    expect(props.stats.map((s) => [s.label, s.value, s.sub])).toEqual([
      ["CPU", "12%", "10 cores"], ["Memory", "19.3 GB", "of 34.4 GB"], ["Disk", "215 GB", "free of 1.1 TB"],
    ]);
    expect(props.running).toEqual([{ id: "respond|acme/web-app#488", title: "Fixing CI on web-app#488", sub: "implementing" }]);
    expect(props.month).toEqual({ total: "$1.20", caption: "estimated · November",
      segments: [{ label: "Reviews", count: "3", amount: "$1.20", value: 1.2, tone: "violet" }] });
    await model.stop("respond|acme/web-app#488");
    expect(app.transport.sent.at(-1)!.command).toEqual({ respondCancel: { pr: "acme/web-app#488" } });
    close();
    expect(app.transport.topics).toEqual(["home"]);
  });
});

describe("settings", () => {
  it("notificaciones de la Mac y Face ID (apagarlo es gated)", async () => {
    const app = makeApp();
    const model = createSettingsModel(app, { version: "PRBar 0.1.0", unpair: async () => {} });
    await model.load();
    const props = model.props.value;
    expect(props.notifications.map((n) => [n.label, n.on])).toEqual([
      ["Review ready", true], ["New PR to review", true], ["Changes requested on my PRs", true], ["Ready to merge", true],
      ["CI failed on my PRs", true],
    ]);
    expect(props.requireFaceId).toMatchObject({ label: REQUIRE_FACE_ID_LABEL, on: true });
    expect(props.mac.secure).toBe("Connected · end-to-end encrypted");
    await model.setNotification("ready-to-merge", false);
    expect(app.transport.sent.at(-1)!.command).toEqual({ notifySet: { kind: "ready-to-merge", enabled: false } });
    expect(model.props.value.notifications[3]!.on).toBe(false);
    await model.setRequireFaceId(false);
    expect(app.transport.sent.at(-1)).toEqual({ command: { remoteSetPresenceRequirement: { device: "", enabled: false } }, presence: true });
    await model.setRequireFaceId(true);
    expect(app.transport.sent.at(-1)).toEqual({ command: { remoteSetPresenceRequirement: { device: "", enabled: true } }, presence: false });
  });

  it("Unpair pregunta primero", async () => {
    const app = makeApp();
    let unpaired = 0;
    const model = createSettingsModel(app, { version: "v", unpair: async () => void unpaired++ });
    app.ui.confirmAnswer = false;
    await model.unpair();
    expect(unpaired).toBe(0);
    app.ui.confirmAnswer = true;
    await model.unpair();
    expect(unpaired).toBe(1);
    expect(app.ui.confirms[0]!.title).toBe("Unpair from Studio?");
  });
});

describe("reloj", () => {
  it("cada segundo cambia `now`; `minute` (y lo que muestra minutos, como Home) solo al pasar el minuto", () => {
    const app = makeApp();
    const home = createHomeModel(app);
    let renders = 0;
    const stop = effect(() => {
      home.props("review");
      renders++;
    });
    app.clock.ms = Math.ceil(NOW / 60_000) * 60_000 + 1000;
    app.store.tick();
    const start = renders;
    for (let i = 0; i < 30; i++) {
      app.clock.ms += 1000;
      app.store.tick();
    }
    expect(app.store.now.value).toBe(app.clock.ms);
    expect(renders).toBe(start);
    app.clock.ms += 30_000;
    app.store.tick();
    expect(renders).toBe(start + 1);
    stop();
  });
});

describe("store", () => {
  it("revocado borra todo y avisa", () => {
    let revoked = 0;
    const app = makeApp();
    const store = new (app.store.constructor as typeof import("../../../src/app/store").AppStore)({
      transport: app.transport, onRevoked: () => revoked++,
    });
    store.attach();
    expect(store.home.value).not.toBeNull();
    app.transport.setState({ kind: "revoked" });
    expect(store.home.value).toBeNull();
    expect(revoked).toBe(1);
  });

  it("el home del buzón solo si es más nuevo", async () => {
    const app = makeApp({ state: { kind: "online" }, attach: false });
    const data = new TextEncoder().encode(fx.topics.find((t) => t.topic === "home")!.text);
    app.transport.mailboxBlobs = [{ slot: "home", rev: 5, createdAt: new Date(NOW - 60_000).toISOString(), data }];
    await app.store.fetchMailbox();
    expect(app.store.lastUpdated.value).toBe(NOW - 60_000);
    app.transport.mailboxBlobs = [{ slot: "home", rev: 6, createdAt: new Date(NOW - 120_000).toISOString(), data }];
    await app.store.fetchMailbox();
    expect(app.store.lastUpdated.value).toBe(NOW - 60_000);
    app.transport.mailboxBlobs = [{ slot: "home", rev: 7, createdAt: new Date(NOW - 8 * 86_400_000).toISOString(), data }];
    app.store.lastUpdated.value = null;
    await app.store.fetchMailbox();
    expect(app.store.lastUpdated.value).toBeNull();
  });
});

// Safari solo muestra Face ID si `credentials.get` se llama dentro del listener del toque: cada botón gated tiene que
// llegar a la passkey sin ningún `await` en el camino (la sesión con la Mac ya está abierta; ver LiveTransport.send).
describe("Face ID en el mismo toque", () => {
  it("Merge, Post (Approve), Tests, Push y apagar Face ID firman antes de volver del click", async () => {
    const app = makeApp();
    const merge = createMergeModel(app, "acme/api#322");
    await merge.load();
    const mergeView = merge.view.value;
    if (mergeView.kind !== "merge") throw new Error(mergeView.kind);
    mergeView.props.onMerge();
    expect(app.signed).toHaveLength(1);

    const review = createReviewModel(app, "acme/api#317");
    const reviewView = review.view.value;
    if (reviewView.kind !== "review") throw new Error(reviewView.kind);
    reviewView.props.onSelectDecision("approve");
    const approve = review.view.value;
    if (approve.kind !== "review") throw new Error(approve.kind);
    approve.props.onPost();
    expect(app.signed).toHaveLength(2);

    const pr = "acme/web-app#488";
    app.transport.setTopic(`pr:${pr}`, { respond: { ...respondInfo(), pr, phase: "readyToPush", testCommand: "npm test" } });
    const respond = createRespondModel(app, pr, "feedback");
    respond.open();
    const fix = respond.view("main");
    if (fix.kind !== "fixci") throw new Error(fix.kind);
    fix.props.onRunTests!();
    expect(app.signed).toHaveLength(3);
    await flush();
    const ready = respond.view("main");
    if (ready.kind !== "fixci") throw new Error(ready.kind);
    ready.props.onPrimary();
    expect(app.signed).toHaveLength(4);

    const settings = createSettingsModel(app, { version: "v", unpair: async () => {} });
    settings.props.value.onToggleFaceId(false);
    expect(app.signed).toHaveLength(5);
    await flush();
  });
});

// Con Face ID apagado para este teléfono (en la Mac) lo que publica o mergea no puede salir de un toque: se pregunta
// antes, como en la Mac y la CLI, y los botones no dicen "requires Face ID".
describe("sin Face ID: confirmar antes de publicar", () => {
  const presenceOff = () => {
    const app = makeApp();
    app.transport.setPresencePolicy({ requirePresence: false, gated: app.transport.presencePolicy.gated });
    return app;
  };

  it("Merge: sin ícono de Face ID, pregunta y, si se cancela, no manda nada", async () => {
    const app = presenceOff();
    const model = createMergeModel(app, "acme/api#322");
    await model.load();
    const view = model.view.value;
    if (view.kind !== "merge") throw new Error(view.kind);
    expect(view.props.mergeFaceId).toBe(false);
    app.ui.confirmAnswer = false;
    await model.merge();
    expect(app.ui.confirms[0]).toMatchObject({ title: "Merge api#322?", confirmLabel: "Merge" });
    expect(sentNames(app)).toEqual(["mergePreview"]);
    app.ui.confirmAnswer = true;
    await model.merge();
    expect(app.transport.sent.at(-1)).toMatchObject({ command: { merge: {} }, presence: false });
    expect(app.signed).toHaveLength(0);
  });

  it("Post (Approve) y Push: preguntan; con Face ID prendido, no", async () => {
    const app = presenceOff();
    const review = createReviewModel(app, "acme/api#317");
    const view = review.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    view.props.onSelectDecision("approve");
    expect((review.view.value as { props: { postFaceId?: boolean } }).props.postFaceId).toBe(false);
    app.ui.confirmAnswer = false;
    await review.post();
    expect(app.ui.confirms.at(-1)).toMatchObject({ title: "Approve api#317?", confirmLabel: "Post" });
    expect(app.transport.sent).toHaveLength(0);

    const pr = "acme/web-app#488";
    app.transport.setTopic(`pr:${pr}`, { respond: { ...respondInfo(), pr, phase: "readyToPush", testCommand: "npm test" } });
    const respond = createRespondModel(app, pr, "feedback");
    respond.open();
    expect(respond.view("main").props).toMatchObject({ primaryFaceId: false, testsFaceId: false });
    await respond.push();
    expect(app.ui.confirms.at(-1)?.title).toMatch(/^Push 1 commit to /);
    expect(app.transport.sent).toHaveLength(0);
    app.ui.confirmAnswer = true;
    await respond.push();
    expect(app.transport.sent.at(-1)).toMatchObject({ command: { respondPush: {} }, presence: false });

    // Con Face ID otra vez: el aviso del sistema es la confirmación.
    app.transport.setPresencePolicy({ requirePresence: true, gated: app.transport.presencePolicy.gated });
    const asked = app.ui.confirms.length;
    expect(respond.view("main").props).toMatchObject({ primaryFaceId: true, testsFaceId: true });
    await review.post();
    expect(app.ui.confirms).toHaveLength(asked);
    expect(app.signed).toHaveLength(1);
  });
});

describe("paso en vivo", () => {
  it("stepElapsed como la Mac", () => {
    expect([0, 12.9, 125, 3780, -5].map(stepElapsed)).toEqual(["0 s", "12 s", "2 min 5 s", "1 h 3 min", "0 s"]);
  });
});
