import type { ComponentChildren } from "preact";
import { Avatar, BlockTitle, BottomBar, Button, DiffCount, DiffView, FaceIdHud, Icon, LogBlock, NavBar, Screen, Spinner } from "../components";
import type { IconName } from "../components";
import { DetailHeader } from "./Review";
import type { FixCIProps, ProgressVM, RespondBaseProps, RespondDiffProps, RespondProps, StatusVM } from "./types";
import "./screens.css";

// respond, respond:fixci y respond:diff: Claude arregla comentarios o CI; el usuario revisa y empuja.

const STATUS_ICON: Record<StatusVM["kind"], IconName> = {
  changes: "exclamationmark.triangle.fill",
  failed: "xmark.octagon.fill",
  passing: "checkmark.circle.fill",
};

function StatusLine({ status }: { status: StatusVM }) {
  return (
    <p class={`detail-status detail-status--${status.kind}`}>
      <Icon name={STATUS_ICON[status.kind]} size={18} />
      {status.text}
    </p>
  );
}

export function ProgressCard({ progress }: { progress: ProgressVM }) {
  return (
    <section class="progress-card" aria-label={progress.title}>
      <h2 class={progress.done ? "progress-card__head progress-card__head--done" : "progress-card__head"}>
        <Icon name={progress.done ? "checkmark.circle.fill" : "sparkles"} size={progress.done ? 19 : 21} />
        <span>{progress.title}</span>
        <span class="progress-card__time">{progress.elapsed}</span>
      </h2>
      <ol class="stages">
        {progress.stages.map((s) => (
          <li key={s.label} class={`stage stage--${s.state}`}>
            <span class="stage__icon">
              {s.state === "current" ? (
                <Spinner size={22} />
              ) : (
                <Icon name={s.state === "done" ? "checkmark.circle.fill" : "circle.dashed"} size={s.state === "done" ? 18 : 20} />
              )}
            </span>
            <span class="stage__text">
              <span class="stage__label">{s.label}</span>
              {s.detail && <span class="stage__detail">{s.detail}</span>}
            </span>
            {s.time && <span class="stage__time">{s.time}</span>}
          </li>
        ))}
      </ol>
    </section>
  );
}

function RespondFrame({ base, title, primaryLabel, children }: {
  base: RespondBaseProps; title: string; primaryLabel: string; children: ComponentChildren;
}) {
  const { pr, status, progress, running, disabled, faceIdPending } = base;
  const label = base.primaryLabel ?? primaryLabel;
  const faceId = base.primaryFaceId !== false;
  return (
    <Screen class="screen--with-bar" label={title}>
      <NavBar
        leading={{ icon: "chevron.left", label: "Back", onClick: base.onBack }}
        title={title}
        trailing={[{ icon: "bubble.left.and.bubble.right", label: "Chat with Claude", onClick: base.onChat }]}
      />
      <DetailHeader pr={pr}>
        <StatusLine status={status} />
      </DetailHeader>
      {base.start ? (
        <Button size="lg" block icon="sparkles" class="start-btn" busy={base.start.busy} disabled={base.start.disabled} onClick={base.start.onClick}>
          {base.start.label}
        </Button>
      ) : (
        <>
          {progress && <ProgressCard progress={progress} />}
          {children}
        </>
      )}
      <BottomBar>
        {base.secondaryHidden ? null : running ? (
          <Button variant="glass" size="lg" icon="stop.fill" class="bar-secondary bar-secondary--stop" disabled={disabled} onClick={base.onStop}>
            Stop
          </Button>
        ) : (
          <Button variant="glass" size="lg" icon="arrow.uturn.backward" class="bar-secondary" disabled={disabled} onClick={base.onUndo}>
            Undo
          </Button>
        )}
        {base.onRunTests && (
          <Button variant="glass" size="lg" icon={base.testsFaceId === false ? "checklist" : "faceid"} class="bar-secondary" label={base.testsFaceId === false ? "Run tests" : "Run tests, requires Face ID"} disabled={disabled || faceIdPending} onClick={base.onRunTests}>
            Tests
          </Button>
        )}
        <Button
          icon={faceId ? "faceid" : undefined}
          class="bar-primary bar-primary--wide"
          label={faceId ? `${label}, requires Face ID` : label}
          disabled={running || disabled || faceIdPending || base.primaryDisabled}
          onClick={base.onPrimary}
        >
          {label}
        </Button>
      </BottomBar>
      {faceIdPending && <FaceIdHud />}
    </Screen>
  );
}

export function Respond(props: RespondProps) {
  const selected = props.comments.filter((c) => c.selected).length;
  return (
    <RespondFrame base={props} title="Respond" primaryLabel="Push & Reply">
      <BlockTitle title="Feedback" trailing={`${selected} of ${props.comments.length} selected`} />
      {props.comments.map((c) => (
        <article key={c.id} class="feedback">
          <button
            type="button"
            role="checkbox"
            aria-checked={c.selected}
            aria-label={`Include comment from ${c.author.name}`}
            class={`checkbox${c.selected ? " checkbox--on" : ""}${props.running ? " checkbox--locked" : ""}`}
            disabled={props.running || props.disabled}
            onClick={() => props.onToggleComment(c.id, !c.selected)}
          >
            {c.selected && <Icon name="checkmark" size={16} />}
          </button>
          <div class="feedback__body">
            <p class="feedback__who">
              <Avatar person={c.author} size={20} />
              <strong>{c.author.name}</strong>
              {c.age && <span class="feedback__age">· {c.age}</span>}
            </p>
            <p class="feedback__loc">{c.location}</p>
            <p class="feedback__text">{c.text}</p>
          </div>
        </article>
      ))}
      {props.changesSummary && (
        <button type="button" class="changes-row" onClick={props.onOpenChanges}>
          <Icon name="doc.text" size={21} />
          <span>{props.changesSummary}</span>
          <Icon name="chevron.right" size={15} class="changes-row__chev" />
        </button>
      )}
    </RespondFrame>
  );
}

export function FixCI(props: FixCIProps) {
  return (
    <RespondFrame base={props} title="Fix CI" primaryLabel="Push">
      <BlockTitle title="Failed checks" trailing={props.failedLabel} />
      {props.checks.map((c) => (
        <article key={c.id} class="check">
          <h3 class="check__head">
            <Icon name="xmark.octagon.fill" size={19} class="tone-red" />
            <span>{c.name}</span>
            <span class="check__time">{c.duration}</span>
          </h3>
          <LogBlock lines={c.log} />
        </article>
      ))}
      {props.files && props.files.length > 0 && (
        <>
          <BlockTitle title="Changed files" />
          <div class="card">
            {props.files.map((f) => (
              <button key={f.id} type="button" class="file-row" onClick={() => props.onOpenFile(f.id)}>
                <Icon name="doc.text" size={20} />
                <span class="file-row__path">{f.path}</span>
                <DiffCount additions={f.additions} deletions={f.deletions} />
                <Icon name="chevron.right" size={15} class="changes-row__chev" />
              </button>
            ))}
          </div>
        </>
      )}
    </RespondFrame>
  );
}

export function RespondDiff(props: RespondDiffProps) {
  const file = props.files.find((f) => f.id === props.selectedFileId) ?? props.files[0];
  return (
    <RespondFrame base={props} title="Changes" primaryLabel={props.primaryLabel}>
      <div class="file-chips" role="tablist" aria-label="Files">
        {props.files.map((f) => (
          <button
            key={f.id}
            type="button"
            role="tab"
            aria-selected={f.id === file?.id}
            class={f.id === file?.id ? "file-chip file-chip--on" : "file-chip"}
            onClick={() => props.onSelectFile(f.id)}
          >
            {f.name}
            <DiffCount additions={f.additions} deletions={f.deletions} />
          </button>
        ))}
      </div>
      {file && <DiffView path={file.path} additions={file.additions} deletions={file.deletions} lines={file.lines} />}
      {props.reply && (
        <section class="reply-card">
          <h2>Reply to {props.reply.to}</h2>
          <p>{props.reply.text}</p>
        </section>
      )}
    </RespondFrame>
  );
}
