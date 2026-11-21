import { Icon, type IconName } from "./Icon";
import { Avatar, DiffCount } from "./basics";
import { ActionCapsule } from "./Button";
import type { PRRowVM, PRStateIcon, PRStatusKind } from "../screens/types";
import "./components.css";

// Fila de PR de Home/My PRs (DESIGN.md "PR row").

const STATE_ICON: Record<PRStateIcon, { icon: IconName; tone: string }> = {
  feedback: { icon: "text.bubble", tone: "orange" },
  ready: { icon: "checkmark", tone: "green" },
  failing: { icon: "xmark", tone: "red" },
};

const STATUS_ICON: Record<PRStatusKind, IconName> = {
  agents: "terminal",
  changes: "exclamationmark.triangle.fill",
  approved: "checkmark.circle.fill",
  failed: "xmark.octagon.fill",
};

export function PRRow({ row, onOpen, onAction }: {
  row: PRRowVM; onOpen?: (() => void) | undefined; onAction?: (() => void) | undefined;
}) {
  const ref = `${row.repo}#${row.number}`;
  const disabled = !!row.disabled;
  const state = row.leading.kind === "state" ? STATE_ICON[row.leading.state] : undefined;
  return (
    <div class={disabled ? "pr-row pr-row--disabled" : "pr-row"}>
      <button
        type="button"
        class="pr-row__hit"
        aria-label={`${row.title}, ${ref}, ${row.age}, ${row.additions} additions, ${row.deletions} deletions`}
        onClick={onOpen}
      />
      <span class="pr-row__lead">
        {row.leading.kind === "avatar" ? (
          <Avatar person={row.leading.person} disabled={disabled} />
        ) : (
          state && (
            <span class={`state-circle state-circle--${disabled ? "disabled" : state.tone}`}>
              <Icon name={state.icon} size={row.leading.state === "feedback" ? 20 : 18} />
            </span>
          )
        )}
      </span>
      <span class="pr-row__body">
        <span class="pr-row__top">
          <span class="pr-row__title">{row.title}</span>
          <span class="pr-row__age">{row.age}</span>
        </span>
        <span class="pr-row__meta">
          {ref} · {row.branch}
        </span>
        {row.status && (
          <span class={`pr-row__status pr-row__status--${row.status.kind}`}>
            <Icon name={STATUS_ICON[row.status.kind]} size={row.status.kind === "agents" ? 18 : 16} />
            {row.status.text}
          </span>
        )}
        <span class="pr-row__bottom">
          <DiffCount additions={row.additions} deletions={row.deletions} />
          {row.action && <ActionCapsule action={row.action} disabled={disabled} onClick={onAction} />}
        </span>
      </span>
    </div>
  );
}
