import { Avatar, Button, Card, DiffCount, FaceIdHud, Icon, ListCaption, ListRow, NavBar, Screen, SegmentedControl } from "../components";
import { Branches, DetailHeader } from "./Review";
import type { MergedProps, MergeMethod, MergeProps } from "./types";
import "./screens.css";

// merge (+ :faceid) y merge:merged.

const METHODS: { id: MergeMethod; label: string }[] = [
  { id: "squash", label: "Squash" },
  { id: "merge", label: "Merge" },
  { id: "rebase", label: "Rebase" },
];

export function Merge(props: MergeProps) {
  const { pr, reviewers, checks, method, merging, faceIdPending, disabled } = props;
  return (
    <Screen label={pr.title}>
      <NavBar
        leading={{ icon: "chevron.left", label: "Back", onClick: props.onBack }}
        trailing={[{ icon: "bubble.left.and.bubble.right", label: "Ask Claude about this PR", onClick: props.onChat }]}
      />
      <DetailHeader pr={pr}>
        <Branches head={pr.head} base={pr.base}>
          <DiffCount additions={pr.additions} deletions={pr.deletions} mono={false} />
        </Branches>
      </DetailHeader>
      <p class="description-card">{props.description}</p>
      <Card class="merge-summary">
        {reviewers.map((r) => (
          <ListRow
            key={r.person.name}
            leading={<Avatar person={r.person} size={26} />}
            label={r.person.name}
            value={r.tone === "green" ? `✓ ${r.state}` : r.state}
            valueTone={r.tone === "neutral" ? "fg2" : r.tone}
          />
        ))}
        <ListRow icon="checklist" label="Checks" value={checks.tone === "green" ? `✓ ${checks.text}` : checks.text} valueTone={checks.tone === "neutral" ? "fg2" : checks.tone} />
        <ListRow icon="text.bubble" label="Unresolved conversations" value={props.unresolved} />
        <ListRow icon="doc.text" label="Files" value={props.files} chevron onClick={props.onFiles} />
      </Card>
      <ListCaption>Merge method</ListCaption>
      <SegmentedControl segments={METHODS} selected={method} label="Merge method" disabled={disabled} onChange={props.onMethod} />
      <p class="merge-note">{props.methodNotes[method]}</p>
      <Button
        size="lg"
        block
        icon="faceid"
        class="merge-btn"
        label="Merge, requires Face ID"
        busy={merging}
        disabled={disabled || faceIdPending}
        onClick={props.onMerge}
      >
        Merge
      </Button>
      {faceIdPending && <FaceIdHud />}
    </Screen>
  );
}

export function Merged({ message, postedIn, onClose, onChat, onViewOnGitHub, onDone }: MergedProps) {
  return (
    <Screen class="result result--nav" label="Merged">
      <NavBar
        leading={{ icon: "xmark", label: "Close", onClick: onClose }}
        trailing={[{ icon: "bubble.left.and.bubble.right", label: "Ask Claude about this PR", onClick: onChat }]}
      />
      <div class="result__body">
        <span class="result__circle result__circle--accent result__circle--lg">
          <Icon name="arrow.triangle.merge" size={50} />
        </span>
        <h1 class="result__title result__title--xl">Merged</h1>
        <p class="result__text">{message}</p>
        {postedIn && (
          <p class="result__chip">
            <Icon name="number" size={15} />
            {postedIn}
          </p>
        )}
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
