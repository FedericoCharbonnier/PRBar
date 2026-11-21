import { Icon } from "./Icon";
import { Button } from "./Button";
import "./components.css";

// Piezas del chat con Claude: burbujas, tarjeta de cambio, "escribiendo" y la caja de texto.

export function ChatBubble({ mine, text, first }: { mine: boolean; text: string; first?: boolean }) {
  return (
    <div class={`bubble-row${mine ? " bubble-row--mine" : ""}${first ? " bubble-row--first" : ""}`}>
      <p class={mine ? "bubble bubble--mine" : "bubble bubble--claude"}>{text}</p>
    </div>
  );
}

/** Tarjeta "Claude hizo un cambio" con Undo. */
export function ActionCard({ title, detail, undoable, onUndo }: {
  title: string; detail: string; undoable: boolean; onUndo?: (() => void) | undefined;
}) {
  return (
    <div class="action-card">
      <span class="action-card__icon">
        <Icon name="pencil" size={20} />
      </span>
      <span class="action-card__text">
        <span class="action-card__title">{title}</span>
        <span class="action-card__detail">{detail}</span>
      </span>
      {undoable && (
        <Button variant="tinted" size="sm" onClick={onUndo} class="action-card__undo">
          Undo
        </Button>
      )}
    </div>
  );
}

export function TypingIndicator() {
  return (
    <div class="typing" role="status" aria-label="Claude is typing">
      <span class="typing__dots" aria-hidden="true">
        <span />
        <span />
        <span />
      </span>
      <span class="typing__label">Claude is typing</span>
    </div>
  );
}

export function Composer({ value, placeholder, disabled, onInput, onSend }: {
  value: string; placeholder: string; disabled?: boolean | undefined; onInput: (v: string) => void; onSend: () => void;
}) {
  const canSend = !disabled && value.trim().length > 0;
  return (
    <form
      class="composer"
      onSubmit={(e) => {
        e.preventDefault();
        if (canSend) onSend();
      }}
    >
      <input
        class="composer__input"
        type="text"
        value={value}
        placeholder={placeholder}
        disabled={disabled}
        aria-label={placeholder}
        enterKeyHint="send"
        onInput={(e) => onInput((e.currentTarget as HTMLInputElement).value)}
      />
      <button type="submit" class={canSend ? "composer__send composer__send--on" : "composer__send"} disabled={!canSend} aria-label="Send">
        <Icon name="arrow.up" size={20} />
      </button>
    </form>
  );
}
