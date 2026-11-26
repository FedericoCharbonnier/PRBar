import type { ComponentChildren } from "preact";
import {
  ActionMenu, Avatar, Banner, BlockTitle, BottomBar, Button, Card, Chip, CodeBlock, DiffCount, FaceIdHud, Icon, ListRow, NavBar,
  Screen, SeverityPill, Sheet, Toggle,
} from "../components";
import type { IconName, MenuItem } from "../components";
import type { EditProps, PRHeaderVM, ReviewDecision, ReviewPostedProps, ReviewProps } from "./types";
import "./screens.css";

// review (+ :menu, :faceid), review:posted y edit (hoja sobre review).

export const DECISIONS: Record<ReviewDecision, { label: string; icon: IconName; tone: "green" | "orange" | undefined }> = {
  comment: { label: "Comment", icon: "text.bubble", tone: undefined },
  request_changes: { label: "Request Changes", icon: "exclamationmark.triangle", tone: "orange" },
  approve: { label: "Approve", icon: "checkmark.circle", tone: "green" },
};

/** `api#317`: el título corto de la barra cuando el del PR pasó por debajo. */
export function shortRef(pr: PRHeaderVM): string {
  return `${pr.repoFull.split("/").pop() ?? pr.repoFull}#${pr.number}`;
}

/** Encabezado de detalle: repo mono + título grande. */
export function DetailHeader({ pr, children }: { pr: PRHeaderVM; children?: ComponentChildren }) {
  return (
    <div class="detail-head">
      <p class="detail-head__repo">
        {pr.repoFull} #{pr.number}
      </p>
      <h1 class="detail-head__title">{pr.title}</h1>
      {children}
    </div>
  );
}

export function Branches({ head, base, children }: { head: string; base: string; children?: ComponentChildren }) {
  return (
    <p class="branches">
      <Chip>{head}</Chip>
      <Icon name="arrow.right" size={14} class="branches__arrow" />
      <Chip>{base}</Chip>
      {children}
    </p>
  );
}

export function Review(props: ReviewProps) {
  const { pr, summary, findings, decision, menuOpen, faceIdPending, posting, disabled } = props;
  const included = findings.filter((f) => f.included).length;
  const d = DECISIONS[decision];
  const items: MenuItem<ReviewDecision>[] = (["comment", "request_changes", "approve"] as const).map((id) => ({
    id, label: DECISIONS[id].label, icon: DECISIONS[id].icon, tone: DECISIONS[id].tone, checked: id === decision,
  }));
  return (
    <Screen class="screen--with-bar" label={pr.title}>
      <NavBar
        leading={{ icon: "chevron.left", label: "Back", onClick: props.onBack }}
        inlineTitle={shortRef(pr)}
        trailing={[
          { icon: "bubble.left.and.bubble.right", label: "Chat with Claude", onClick: props.onChat },
          { icon: "ellipsis", label: "More", onClick: props.onMore },
        ]}
      />
      <DetailHeader pr={pr}>
        <p class="author-line">
          <Avatar person={pr.author} size={22} />
          <span>
            {pr.author.name} · {pr.age}
          </span>
          <DiffCount additions={pr.additions} deletions={pr.deletions} mono={false} />
          <span>· {pr.files} files</span>
        </p>
        <Branches head={pr.head} base={pr.base} />
      </DetailHeader>
      {props.error && <Banner banner={{ tone: "red", icon: "exclamationmark.triangle", text: props.error }} />}
      {props.start ? (
        <Button size="lg" block icon="sparkles" class="start-btn" busy={props.start.busy} disabled={props.start.disabled} onClick={props.start.onClick}>
          {props.start.label}
        </Button>
      ) : (
        <>
        <section class="summary-card">
          <h2>
            <Icon name="sparkles" size={21} />
            <span>Claude's summary</span>
            <span class="summary-card__meta">{summary.meta}</span>
          </h2>
          <p>{summary.text}</p>
        </section>
        {props.previous && (
          <>
            <BlockTitle title="Previous comments" trailing={props.previous.header} />
            {props.previous.comments.map((c) => (
              <article key={c.id} class={`finding previous previous--${c.status}`}>
                <div class="finding__head">
                  <span class="previous__status">{c.statusLabel}</span>
                  <span class="finding__loc">{c.location}</span>
                  <span class="previous__github">{c.github}</span>
                </div>
                {c.note && <p>{c.note}</p>}
                <details class="previous__text">
                  <summary>Posted comment</summary>
                  <p>{c.text}</p>
                </details>
              </article>
            ))}
          </>
        )}
        {props.recommendation && (
          <p class="recommendation">
            <Icon name="sparkles" size={16} />
            <span>Recommended: {props.recommendation.label} · {props.recommendation.reason}</span>
          </p>
        )}
        <BlockTitle title="Findings" trailing={`${included} of ${findings.length} included`} />
        {findings.map((f, i) => (
          <article key={f.id} class={f.included ? "finding" : "finding finding--off"}>
            <div class="finding__head">
              <SeverityPill severity={f.severity} />
              <span class="finding__loc">{f.location}</span>
              <Toggle
                on={f.included}
                disabled={disabled}
                label={`Include finding ${i + 1}, ${f.severity}`}
                onChange={(on) => props.onToggleFinding(f.id, on)}
              />
            </div>
            <h3>{f.title}</h3>
            <p>{f.text}</p>
            <button type="button" class="finding__edit" disabled={disabled} onClick={() => props.onEditFinding(f.id)}>
              <Icon name="pencil" size={18} />
              Edit comment
            </button>
          </article>
        ))}
        </>
      )}
      <BottomBar>
        <button
          type="button"
          class="decision"
          aria-label={`Review decision: ${d.label}`}
          aria-haspopup="menu"
          disabled={disabled}
          onClick={props.onOpenDecisionMenu}
        >
          <Icon name={d.icon} size={21} class={d.tone ? `tone-${d.tone}` : undefined} />
          <span>{d.label}</span>
          <Icon name="chevron.up.chevron.down" size={16} class="decision__chev" />
        </button>
        <Button
          icon={props.postFaceId === false ? undefined : "faceid"}
          class="bar-primary"
          label={props.postFaceId === false ? "Post review" : "Post review, requires Face ID"}
          busy={posting}
          disabled={disabled || faceIdPending}
          onClick={props.onPost}
        >
          Post
        </Button>
      </BottomBar>
      {menuOpen && (
        <ActionMenu
          items={items}
          label="Review decision"
          onSelect={props.onSelectDecision}
          onDismiss={props.onCloseDecisionMenu}
        />
      )}
      {faceIdPending && <FaceIdHud />}
    </Screen>
  );
}

const DECISION_RESULT: Record<ReviewDecision, string> = {
  approve: "Approve",
  request_changes: "Request Changes",
  comment: "Comment",
};

/** Pantalla de resultado con círculo, título, texto, tarjeta y botones abajo (review:posted, merge:merged). */
export function ReviewPosted({ decision, message, inlineComments, postedFrom, onViewOnGitHub, onDone }: ReviewPostedProps) {
  const tone = decision === "approve" ? "green" : decision === "request_changes" ? "orange" : "fg2";
  return (
    <Screen class="result" label="Review posted">
      <div class="result__body">
        <span class="result__circle result__circle--green">
          <Icon name="checkmark" size={46} />
        </span>
        <h1 class="result__title">Review posted</h1>
        <p class="result__text">{message}</p>
        <Card class="result__card">
          <ListRow label="Decision" value={DECISION_RESULT[decision]} valueTone={tone} />
          <ListRow label="Inline comments" value={inlineComments} />
          <ListRow label="Posted from" value={postedFrom} />
        </Card>
      </div>
      <div class="result__footer">
        <Button variant="tinted" size="lg" block trailingIcon="arrow.up.right" onClick={onViewOnGitHub}>
          View on GitHub
        </Button>
        <Button size="lg" block onClick={onDone}>
          Done
        </Button>
      </div>
    </Screen>
  );
}

/** edit — hoja grande para editar el comentario de un hallazgo (la pantalla de atrás queda como tarjeta). */
export function Edit({ subtitle, severity, location, excerpt, text, line, saving, onChange, onSave, onDiscard }: EditProps) {
  return (
    <Sheet detent="large" label="Edit Comment" onDismiss={onDiscard}>
      <div class="edit">
        <div class="edit__head">
          <Button variant="glass" size="md" class="edit__discard" onClick={onDiscard}>
            Discard
          </Button>
          <div class="edit__title">
            <h1>Edit Comment</h1>
            <p>{subtitle}</p>
          </div>
          <Button size="md" class="edit__save" busy={saving} onClick={onSave}>
            Save
          </Button>
        </div>
        <p class="edit__loc">
          <SeverityPill severity={severity} />
          <span>{location}</span>
        </p>
        {excerpt && excerpt.length > 0 && <CodeBlock lines={excerpt} />}
        <h2 class="edit__caption">Comment</h2>
        <textarea
          class="edit__editor"
          value={text}
          aria-label="Comment"
          onInput={(e) => onChange((e.currentTarget as HTMLTextAreaElement).value)}
        />
        <p class="edit__footer">Markdown supported · posts on line {line}</p>
      </div>
    </Sheet>
  );
}
