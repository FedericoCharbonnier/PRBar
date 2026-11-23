// @vitest-environment happy-dom
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { cleanup, fireEvent, render, screen } from "@testing-library/preact";
import { afterEach, describe, expect, it, vi } from "vitest";
import { stories } from "../../../src/stories/stories";
import * as d from "../../../src/stories/data";
import { Chat, Home, Merge, PairWelcome, Review, Settings } from "../../../src/ui/screens";
import { TabBar } from "../../../src/ui/components";

afterEach(cleanup);

// Textos clave por historia (copia exacta de DESIGN.md).
const copy: Record<string, string[]> = {
  install: ["Add PRBar to your Home Screen", "Tap Share", "Add to Home Screen", "Open PRBar from the icon"],
  "pair:welcome": ["Welcome to PRBar", "Your Mac does the work. Your iPhone is the remote.", "Live from your Mac",
    "Act from anywhere", "End-to-end encrypted", "Device name", "Scan QR on your Mac",
    "On your Mac, open PRBar › Settings › Pair iPhone."],
  "pair:scan": ["Scan the QR code", "It's in PRBar › Settings › Pair iPhone on your Mac.", "End-to-end encrypted pairing", "Paste code"],
  "pair:confirm": ["Pair with Diego's MacBook Pro?", "relay.example.com", "This replaces your pairing with Studio Mac.", "Replace and Pair", "Cancel"],
  "pair:sas": ["Confirm on your Mac", "Connected through an encrypted relay"],
  "pair:paired": ["Paired with Diego's MacBook Pro", "Allow notifications"],
  home: ["To Review", "Updated Since My Review", "Add CSV export to the monthly reports page", "web-app#491 · develop",
    "2 agents · on devbox", "Reviewing…", "4 comments", "Connected · updated just now"],
  "home:mine": ["My PRs", "My PRs with Feedback", "Ready to Merge", "CI Failing", "Waiting for Review",
    "Changes requested · 2 comments", "Approved by 2 · checks passing", "2 checks failed", "Respond", "Merge…", "Fix CI"],
  "home:offline": ["Diego's MacBook Pro is offline or asleep", "Try Again", "Offline · last seen 8:12 AM"],
  review: ["acme/api #317", "Claude's summary", "2 agents · 3m 40s", "Findings", "3 of 4 included", "Edit comment", "Approve", "Post"],
  "review:menu": ["Comment", "Request Changes", "Approve"],
  "review:faceid": ["Waiting for Face ID…"],
  "review:posted": ["Review posted", "Approved api#317 with 3 comments.", "Decision", "Inline comments", "Posted from",
    "View on GitHub", "Done"],
  edit: ["Edit Comment", "Finding 1 of 4", "Discard", "Save", "Markdown supported · posts on line 88"],
  respond: ["Respond", "Changes requested by Laura Méndez", "Claude is fixing 2 comments", "Analyzing", "Implementing",
    "Running tests", "Editing src/reports/export.ts", "Feedback", "2 of 2 selected", "Stop", "Push & Reply"],
  "respond-done": ["Fixed · tests passing", "142 passed", "Undo", "2 files changed, 15 insertions(+), 4 deletions(-)"],
  "respond:fixci": ["Fix CI", "2 checks failed", "Claude is fixing 2 checks", "Failed checks", "2 of 9", "unit-tests", "lint", "Push"],
  "respond:diff": ["Changes", "src/reports/export.ts", "export.test.ts", "Reply to Laura Méndez"],
  merge: ["acme/api #322", "Make payment retries idempotent", "feat/idempotent-retries", "Checks", "✓ 9 passing",
    "Unresolved conversations", "None", "4 changed", "Merge method", "Squash", "Rebase", "3 commits become one commit on main."],
  "merge:faceid": ["Waiting for Face ID…"],
  "merge:merged": ["Merged", "api#322 was squashed into main.", "Posted in #api-reviews", "View on GitHub", "Done"],
  "chat:review": ["Claude", "api#317 · Review", "Today 9:32 AM", "Changed finding #3", "Severity Medium → Low", "Undo"],
  "chat:respond": ["web-app#475 · Respond", "Edited fix in src/reports/export.ts", "+1 −1 · tests re-running"],
  "chat:merge": ["api#322 · Merge", "Read-only. Claude can answer questions about this PR but won't change it."],
  activity: ["Activity", "CPU", "38%", "Memory", "11.2 GB", "Disk", "212 GB", "Running", "Reviewing api#317",
    "Claude this month", "$48.20", "estimated · November", "Reviews", "$29.10", "46 msgs"],
  settings: ["Settings", "Unpair This Mac", "Notifications", "Review ready", "New PR to review", "Changes requested on my PRs",
    "Ready to merge", "CI failed on my PRs", "Security", "Require Face ID for posting to GitHub, merge, push and tests", "PRBar 0.1.0 (demo)"],
};

const noop = () => {};

describe("historias", () => {
  it("cubren cada pantalla de DESIGN.md", () => {
    const ids = new Set(stories.map((s) => s.id));
    for (const id of Object.keys(copy)) expect(ids, id).toContain(id);
  });

  for (const story of stories) {
    it(`${story.id} se dibuja con los textos del diseño`, () => {
      const { container } = render(story.render());
      // Las hojas se dibujan aparte, en #overlay-root (fuera de la pantalla, para la presentación tipo tarjeta).
      const overlays = document.getElementById("overlay-root")?.innerHTML ?? "";
      expect(container.innerHTML.length + overlays.length).toBeGreaterThan(50);
      const text = document.body.textContent ?? "";
      for (const s of copy[story.id] ?? []) expect(text, `${story.id}: ${s}`).toContain(s);
    });
  }

});

describe("CSP", () => {
  // La CSP del relay no permite estilos ni scripts en línea: los estilos van en .css y, si hace falta uno dinámico,
  // como objeto `style` (Preact lo pone por CSSOM). Nada de `style="…"` en texto ni HTML crudo.
  // Vitest corre desde web/ (en happy-dom, import.meta.url no es file://).
  const dir = join(process.cwd(), "src/ui");
  const files = readdirSync(dir, { recursive: true }).map(String).filter((f) => f.endsWith(".tsx") || f.endsWith(".ts"));

  it("los componentes no escriben estilos ni HTML en línea", () => {
    expect(files.length).toBeGreaterThan(10);
    for (const f of files) {
      const src = readFileSync(join(dir, f), "utf8");
      expect(src, f).not.toMatch(/style="/);
      expect(src, f).not.toMatch(/style=\{`/);
      expect(src, f).not.toMatch(/dangerouslySetInnerHTML/);
      expect(src, f).not.toMatch(/<style/);
    }
  });
});

describe("callbacks", () => {
  it("home: abrir fila, acción y plegar sección", () => {
    const onOpen = vi.fn(), onAction = vi.fn(), onToggleSection = vi.fn();
    render(<Home mac={d.macOnline} title="To Review" sections={d.reviewSections} onOpen={onOpen} onAction={onAction}
      onToggleSection={onToggleSection} />);
    fireEvent.click(screen.getByLabelText(/Add CSV export to the monthly reports page, web-app#491/));
    expect(onOpen).toHaveBeenCalledWith("web-app#491");
    fireEvent.click(screen.getByRole("button", { name: "Review" }));
    expect(onAction).toHaveBeenCalledWith("web-app#491");
    expect(onOpen).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "To Review, 2, expanded" }));
    expect(onToggleSection).toHaveBeenCalledWith("review");
    // Sin botones que no hacen nada: ni Filter (sin comportamiento en DESIGN.md) ni la píldora de la Mac.
    expect(screen.queryByRole("button", { name: "Filter" })).toBeNull();
    expect(screen.queryByRole("button", { name: /Diego/ })).toBeNull();
    expect(screen.getByRole("img", { name: /Diego's MacBook Pro, connected/ })).toBeTruthy();
  });

  it("home:offline: la acción queda deshabilitada y se anuncia", () => {
    render(<Home mac={d.macOffline} title="To Review" sections={d.reviewSectionsOffline} onOpen={noop} onAction={noop}
      onToggleSection={noop} offline={{ title: "x", message: "y" }} onRetry={noop} />);
    const btn = screen.getByRole("button", { name: "Review, unavailable" }) as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
  });

  it("pair:welcome: nombre del dispositivo y Pair", () => {
    const onName = vi.fn(), onPair = vi.fn();
    render(<PairWelcome deviceName="iPhone" onDeviceNameChange={onName} onPair={onPair} />);
    const input = screen.getByLabelText("Device name") as HTMLInputElement;
    expect(input.value).toBe("iPhone");
    fireEvent.input(input, { target: { value: "Diego's iPhone" } });
    expect(onName).toHaveBeenCalledWith("Diego's iPhone");
    fireEvent.click(screen.getByRole("button", { name: /Scan QR on your Mac/ }));
    expect(onPair).toHaveBeenCalled();
  });

  it("review: hallazgos, decisión y Post", () => {
    const onToggleFinding = vi.fn(), onSelectDecision = vi.fn(), onPost = vi.fn(), onOpen = vi.fn();
    render(<Review pr={d.reviewPR} summary={d.reviewSummary} findings={d.findings} decision="approve" menuOpen
      onBack={noop} onChat={noop} onMore={noop} onToggleFinding={onToggleFinding} onEditFinding={noop}
      onOpenDecisionMenu={onOpen} onCloseDecisionMenu={noop} onSelectDecision={onSelectDecision} onPost={onPost} />);
    fireEvent.click(screen.getByLabelText("Include finding 4, low"));
    expect(onToggleFinding).toHaveBeenCalledWith("f4", true);
    fireEvent.click(screen.getByRole("menuitemradio", { name: /Request Changes/ }));
    expect(onSelectDecision).toHaveBeenCalledWith("request_changes");
    fireEvent.click(screen.getByRole("button", { name: "Review decision: Approve" }));
    expect(onOpen).toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Post review, requires Face ID" }));
    expect(onPost).toHaveBeenCalled();
  });

  it("merge: método y botón con Face ID", () => {
    const onMethod = vi.fn(), onMerge = vi.fn();
    render(<Merge {...d.mergeProps} onBack={noop} onChat={noop} onFiles={noop} onMethod={onMethod} onMerge={onMerge} />);
    fireEvent.click(screen.getByRole("radio", { name: "Rebase" }));
    expect(onMethod).toHaveBeenCalledWith("rebase");
    fireEvent.click(screen.getByRole("button", { name: "Merge, requires Face ID" }));
    expect(onMerge).toHaveBeenCalled();
  });

  it("sin Face ID, Merge y Post no lo prometen", () => {
    render(<Merge {...d.mergeProps} mergeFaceId={false} onBack={noop} onChat={noop} onFiles={noop} onMethod={noop} onMerge={noop} />);
    expect(screen.getByRole("button", { name: "Merge" })).toBeDefined();
    expect(screen.queryByRole("button", { name: /requires Face ID/ })).toBeNull();
    cleanup();
    render(<Review pr={d.reviewPR} summary={d.reviewSummary} findings={d.findings} decision="approve" postFaceId={false}
      onBack={noop} onChat={noop} onMore={noop} onToggleFinding={noop} onEditFinding={noop}
      onOpenDecisionMenu={noop} onCloseDecisionMenu={noop} onSelectDecision={noop} onPost={noop} />);
    expect(screen.getByRole("button", { name: "Post review" })).toBeDefined();
  });

  it("review fallido: el motivo y Try Again", () => {
    const onStart = vi.fn();
    render(<Review pr={d.reviewPR} summary={d.reviewSummary} findings={[]} decision="comment" error="claude exited with code 1."
      start={{ label: "Try Again", onClick: onStart }} disabled onBack={noop} onChat={noop} onMore={noop}
      onToggleFinding={noop} onEditFinding={noop} onOpenDecisionMenu={noop} onCloseDecisionMenu={noop}
      onSelectDecision={noop} onPost={noop} />);
    expect(screen.getByText("claude exited with code 1.")).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Try Again" }));
    expect(onStart).toHaveBeenCalled();
  });

  it("merge:faceid deshabilita el botón mientras espera", () => {
    render(<Merge {...d.mergeProps} faceIdPending onBack={noop} onChat={noop} onFiles={noop} onMethod={noop} onMerge={noop} />);
    expect((screen.getByRole("button", { name: "Merge, requires Face ID" }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole("status").textContent).toContain("Waiting for Face ID…");
  });

  it("chat: enviar solo con texto; undo de la tarjeta", () => {
    const onSend = vi.fn(), onUndo = vi.fn();
    const { rerender } = render(<Chat context="api#317 · Review" readOnly={false} items={d.chatReview} draft=""
      placeholder="Message Claude" onBack={noop} onDraft={noop} onSend={onSend} onUndo={onUndo} />);
    expect((screen.getByRole("button", { name: "Send" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(onUndo).toHaveBeenCalledWith("a1");
    rerender(<Chat context="api#317 · Review" readOnly={false} items={d.chatReview} draft="hola"
      placeholder="Message Claude" onBack={noop} onDraft={noop} onSend={onSend} onUndo={onUndo} />);
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(onSend).toHaveBeenCalled();
  });

  it("chat: mientras Claude contesta, Send es Stop", () => {
    const onStop = vi.fn();
    render(<Chat context="api#317 · Review" readOnly={false} items={d.chatReview} draft="" running disabled
      placeholder="Message Claude" onBack={noop} onDraft={noop} onSend={noop} onStop={onStop} onUndo={noop} />);
    expect(screen.queryByRole("button", { name: "Send" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    expect(onStop).toHaveBeenCalled();
  });

  it("settings: interruptores", () => {
    const onToggleNotification = vi.fn(), onToggleFaceId = vi.fn(), onUnpair = vi.fn();
    render(<Settings {...d.settings} onUnpair={onUnpair} onToggleNotification={onToggleNotification} onToggleFaceId={onToggleFaceId} />);
    fireEvent.click(screen.getByRole("switch", { name: "Ready to merge" }));
    expect(onToggleNotification).toHaveBeenCalledWith("readyToMerge", false);
    fireEvent.click(screen.getByRole("switch", { name: "Require Face ID for posting to GitHub, merge, push and tests" }));
    expect(onToggleFaceId).toHaveBeenCalledWith(false);
    fireEvent.click(screen.getByRole("button", { name: "Unpair This Mac" }));
    expect(onUnpair).toHaveBeenCalled();
  });

  it("tab bar: pestañas, selección e insignia", () => {
    const onSelect = vi.fn();
    render(<TabBar selected="mine" reviewBadge={3} onSelect={onSelect} />);
    expect(screen.getByRole("tab", { name: /My PRs/ }).getAttribute("aria-selected")).toBe("true");
    expect(screen.getByRole("tab", { name: /To Review/ }).textContent).toContain("3");
    fireEvent.click(screen.getByRole("tab", { name: /Settings/ }));
    expect(onSelect).toHaveBeenCalledWith("settings");
  });
});
