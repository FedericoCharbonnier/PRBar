import { ActionCard, ChatBubble, Composer, Icon, NavBar, Screen, TypingIndicator } from "../components";
import { usePage } from "../nav/context";
import { useStickToBottom } from "../nav/stickToBottom";
import type { ChatProps } from "./types";
import "./screens.css";

// chat:review, chat:respond, chat:merge (solo lectura).
export function Chat({ context, readOnly, timestamp, items, typing, draft, placeholder, disabled, onBack, onDraft, onSend, onUndo }: ChatProps) {
  let prev: string | undefined;
  // Abre en el último mensaje y lo sigue mientras llegan mensajes o la respuesta (si no se subió a leer).
  const last = items.at(-1);
  const content = `${items.length}|${last && last.kind !== "action" ? last.text.length : ""}|${typing ? 1 : 0}`;
  const stick = useStickToBottom(usePage()?.scroller, content);
  return (
    <Screen variant="plain" class="chat" label="Claude">
      <NavBar leading={{ icon: "chevron.left", label: "Back", onClick: onBack }} title="Claude" titleIcon="sparkles" subtitle={context} />
      {readOnly && (
        <p class="chat__notice">
          <Icon name="lock.fill" size={15} />
          Read-only. Claude can answer questions about this PR but won't change it.
        </p>
      )}
      {timestamp && <p class="chat__time">{timestamp}</p>}
      <div class="chat__log" role="log" aria-live="polite">
        {items.map((it, i) => {
          const speaker = it.kind === "mine" ? "mine" : "claude";
          const first = i > 0 && speaker !== prev;
          prev = speaker;
          if (it.kind === "action") {
            return <ActionCard key={it.id} title={it.title} detail={it.detail} undoable={it.undoable} onUndo={() => onUndo(it.id)} />;
          }
          return <ChatBubble key={it.id} mine={it.kind === "mine"} text={it.text} first={first} />;
        })}
        {typing && <TypingIndicator />}
      </div>
      <div class="chat__input">
        <Composer value={draft} placeholder={placeholder} disabled={disabled} onInput={onDraft} onSend={() => {
          onSend();
          stick();
        }} />
      </div>
    </Screen>
  );
}
