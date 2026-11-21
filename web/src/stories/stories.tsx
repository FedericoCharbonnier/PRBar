import type { JSX } from "preact";
import {
  Activity, Chat, Edit, FixCI, Home, Install, Merge, Merged, PairConfirm, PairPaired, PairSas, PairScan, PairWelcome,
  Respond, RespondDiff, Review, ReviewPosted, Settings,
} from "../ui/screens";
import { ActionCapsule, Avatar, Button, Chip, Icon, LargeTitle, MacPill, SeverityPill, TabBar } from "../ui/components";
import * as d from "./data";

// Registro de historias: una por id de pantalla de DESIGN.md (más algunas variantes). Callbacks vacíos: son de muestra.

const noop = () => {};
const noop1 = (_: unknown) => {};
const noop2 = (_: unknown, __: unknown) => {};

export interface Story {
  /** Id del diseño (`home:mine`); la captura se llama igual con `_` en lugar de `:`. */
  id: string;
  render: () => JSX.Element;
  /** Captura de la página entera (no solo el viewport). */
  fullPage?: boolean;
}

const homeBase = { onOpen: noop1, onAction: noop1, onToggleSection: noop1, onFilter: noop };

const review = (extra: Partial<Parameters<typeof Review>[0]> = {}) => (
  <Review
    pr={d.reviewPR}
    summary={d.reviewSummary}
    findings={d.findings}
    decision="approve"
    onBack={noop}
    onChat={noop}
    onMore={noop}
    onToggleFinding={noop2}
    onEditFinding={noop1}
    onOpenDecisionMenu={noop}
    onCloseDecisionMenu={noop}
    onSelectDecision={noop1}
    onPost={noop}
    {...extra}
  />
);

const respondBase = { onBack: noop, onChat: noop, onStop: noop, onUndo: noop, onPrimary: noop };

const merge = (extra: Partial<Parameters<typeof Merge>[0]> = {}) => (
  <Merge {...d.mergeProps} onBack={noop} onChat={noop} onFiles={noop} onMethod={noop1} onMerge={noop} {...extra} />
);

const chatBase = { onBack: noop, onDraft: noop1, onSend: noop, onUndo: noop1, draft: "" };

function Styleguide() {
  return (
    <main class="screen styleguide">
      <LargeTitle>Style guide</LargeTitle>
      <div class="sg-swatches">
        {["bg", "bg2", "bg3", "fg", "fg2", "fg3", "sep", "fill", "fill2", "accent", "accentfg", "accentbg", "green", "greenbg",
          "orange", "orangebg", "red", "redbg", "violet", "violetbg", "blue", "bluebg", "codebg", "addbg", "delbg"].map((t) => (
          <figure key={t}>
            <span class={`sg-swatch sg-swatch--${t}`} />
            <figcaption>{t}</figcaption>
          </figure>
        ))}
      </div>
      <MacPill mac={d.macOnline} />
      <div class="sg-row">
        <ActionCapsule action={{ kind: "review", label: "Review" }} />
        <ActionCapsule action={{ kind: "reviewing", label: "Reviewing…" }} />
        <ActionCapsule action={{ kind: "comments", label: "4 comments" }} />
      </div>
      <div class="sg-row">
        <ActionCapsule action={{ kind: "respond", label: "Respond" }} />
        <ActionCapsule action={{ kind: "merge", label: "Merge…" }} />
        <ActionCapsule action={{ kind: "fixci", label: "Fix CI" }} />
        <ActionCapsule action={{ kind: "review", label: "Review" }} disabled />
      </div>
      <div class="sg-row">
        <SeverityPill severity="high" />
        <SeverityPill severity="medium" />
        <SeverityPill severity="low" />
        <Avatar person={d.people.laura} />
        <span class="state-circle state-circle--orange"><Icon name="text.bubble" size={20} /></span>
        <span class="state-circle state-circle--green"><Icon name="checkmark" size={18} /></span>
        <span class="state-circle state-circle--red"><Icon name="xmark" size={18} /></span>
      </div>
      <p class="branches">
        <Chip>fix/session-expiry</Chip>
        <Icon name="arrow.right" size={14} class="branches__arrow" />
        <Chip>main</Chip>
        <span>· 5 files</span>
      </p>
      <Button size="lg" block icon="faceid">Post</Button>
      <div class="sg-row">
        <Button variant="tinted" size="lg" trailingIcon="arrow.up.right" class="sg-grow">View on GitHub</Button>
        <Button variant="glass" size="lg" icon="arrow.uturn.backward">Undo</Button>
      </div>
    </main>
  );
}

export const stories: Story[] = [
  { id: "install", render: () => <Install platform="ios" /> },
  { id: "install:android", render: () => <Install platform="android" canInstall onInstall={noop} /> },
  { id: "pair:welcome", render: () => <PairWelcome deviceName="iPhone" onDeviceNameChange={noop1} onPair={noop} /> },
  { id: "pair:scan", render: () => <PairScan onCancel={noop} onPasteCode={noop} /> },
  {
    id: "pair:scan-paste",
    render: () => (
      <PairScan onCancel={noop} onPasteCode={noop} paste={{ value: "", onChange: noop1, onSubmit: noop, onCancel: noop }} />
    ),
  },
  {
    id: "pair:confirm",
    render: () => <PairConfirm macName="Diego's MacBook Pro" relayHost="relay.example.com" replacing="Studio Mac" onConfirm={noop} onCancel={noop} />,
  },
  { id: "pair:sas", render: () => <PairSas macName="Diego's MacBook Pro" code="123456" onMismatch={noop} /> },
  {
    id: "pair:paired",
    render: () => <PairPaired macName="Diego's MacBook Pro" notifications="default" onAllowNotifications={noop} onContinue={noop} />,
  },
  { id: "home", render: () => <Home {...homeBase} mac={d.macOnline} title="To Review" sections={d.reviewSections} /> },
  { id: "home:mine", render: () => <Home {...homeBase} mac={d.macOnline} title="My PRs" sections={d.mineSections} /> },
  {
    id: "home:offline",
    render: () => (
      <Home
        {...homeBase}
        mac={d.macOffline}
        title="To Review"
        sections={d.reviewSectionsOffline}
        offline={{
          title: "Diego's MacBook Pro is offline or asleep",
          message: "Last connected today at 8:12 AM. You're seeing cached data, and actions are off until your Mac is back.",
        }}
        onRetry={noop}
      />
    ),
  },
  {
    id: "home:stale",
    render: () => (
      <Home
        {...homeBase}
        mac={d.macOnline}
        title="To Review"
        sections={d.reviewSections}
        banner={{ tone: "neutral", icon: "clock", text: "Showing data from 5 min ago.", actionLabel: "Refresh" }}
      />
    ),
  },
  {
    id: "tabbar",
    render: () => (
      <>
        <Home {...homeBase} mac={d.macOnline} title="To Review" sections={d.reviewSections} />
        <TabBar selected="review" reviewBadge={2} onSelect={noop1} />
      </>
    ),
  },
  { id: "review", render: () => review() },
  { id: "review-full", render: () => review(), fullPage: true },
  { id: "review:menu", render: () => review({ menuOpen: true }) },
  { id: "review:faceid", render: () => review({ faceIdPending: true }) },
  {
    id: "review:posted",
    render: () => (
      <ReviewPosted
        decision="approve"
        message="Approved api#317 with 3 comments."
        inlineComments={3}
        postedFrom="Diego's MacBook Pro"
        onViewOnGitHub={noop}
        onDone={noop}
      />
    ),
  },
  {
    id: "edit",
    render: () => (
      <Edit
        subtitle="Finding 1 of 4"
        severity="high"
        location="src/auth/session.ts:88"
        text={d.findings[0]?.text ?? ""}
        line={88}
        onChange={noop1}
        onSave={noop}
        onDiscard={noop}
      />
    ),
  },
  {
    id: "respond",
    render: () => (
      <Respond
        {...respondBase}
        pr={d.respondPR}
        status={{ kind: "changes", text: "Changes requested by Laura Méndez" }}
        progress={d.progressRespond}
        running
        comments={d.comments}
        onToggleComment={noop2}
        onOpenChanges={noop}
      />
    ),
  },
  {
    id: "respond-done",
    render: () => (
      <Respond
        {...respondBase}
        pr={d.respondPR}
        status={{ kind: "passing", text: "2 files · tests passing" }}
        progress={d.progressDone}
        running={false}
        comments={d.comments}
        changesSummary="2 files changed, 15 insertions(+), 4 deletions(-)"
        onToggleComment={noop2}
        onOpenChanges={noop}
      />
    ),
  },
  {
    id: "respond:fixci",
    render: () => (
      <FixCI
        {...respondBase}
        pr={d.fixciPR}
        status={{ kind: "failed", text: "2 checks failed" }}
        progress={d.progressFixci}
        running
        failedLabel="2 of 9"
        checks={d.failedChecks}
        onOpenFile={noop1}
      />
    ),
  },
  {
    id: "respond:diff",
    render: () => (
      <RespondDiff
        {...respondBase}
        pr={d.respondPR}
        status={{ kind: "passing", text: "2 files · tests passing" }}
        running={false}
        files={d.diffFiles}
        selectedFileId="export"
        reply={{ to: "Laura Méndez", text: "Good catch — it now streams rows with a cursor, so memory stays flat on big months." }}
        primaryLabel="Push & Reply"
        onSelectFile={noop1}
      />
    ),
  },
  { id: "merge", render: () => merge() },
  { id: "merge:faceid", render: () => merge({ faceIdPending: true }) },
  {
    id: "merge:merged",
    render: () => (
      <Merged
        message="api#322 was squashed into main."
        postedIn="Posted in #api-reviews"
        onClose={noop}
        onChat={noop}
        onViewOnGitHub={noop}
        onDone={noop}
      />
    ),
  },
  {
    id: "chat:review",
    render: () => (
      <Chat {...chatBase} context="api#317 · Review" readOnly={false} timestamp="Today 9:32 AM" items={d.chatReview} placeholder="Message Claude" />
    ),
  },
  {
    id: "chat:respond",
    render: () => (
      <Chat {...chatBase} context="web-app#475 · Respond" readOnly={false} timestamp="Today 9:34 AM" items={d.chatRespond} placeholder="Message Claude" />
    ),
  },
  {
    id: "chat:merge",
    render: () => (
      <Chat {...chatBase} context="api#322 · Merge" readOnly timestamp="Today 9:35 AM" items={d.chatMerge} placeholder="Ask about this PR" />
    ),
  },
  {
    id: "chat:typing",
    render: () => (
      <Chat {...chatBase} context="api#317 · Review" readOnly={false} timestamp="Today 9:32 AM" items={d.chatReview.slice(0, 1)} typing draft="Anything else?" placeholder="Message Claude" />
    ),
  },
  { id: "activity", render: () => <Activity {...d.activity} onStop={noop1} /> },
  {
    id: "settings",
    render: () => <Settings {...d.settings} onUnpair={noop} onToggleNotification={noop2} onToggleFaceId={noop1} />,
  },
  { id: "styleguide", render: () => <Styleguide /> },
];

/** Nombre de archivo de la captura (`home:mine` → `home_mine`). */
export function snapshotName(id: string): string {
  return id.replace(/:/g, "_");
}
