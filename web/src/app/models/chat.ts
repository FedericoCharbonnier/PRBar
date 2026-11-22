import { computed, signal, type ReadonlySignal } from "@preact/signals";
import type { ChatInfo } from "../../protocol/commands";
import type { ChatItemVM, ChatProps } from "../../ui/screens/types";
import type { AppContext } from "../context";
import { chatStamp, parseDate, shortRef } from "../format";
import type { ChatKind } from "../router";
import { perform, undoWithConfirmation } from "./common";

// chat:review, chat:respond, chat:merge (ChatModel.swift): el mismo chat con Claude que el panel de la Mac. El texto
// llega como eventos del `chatSend` propio; un chat que sigue en la Mac llega como `chatDelta` (se ignora mientras
// corre el propio, que ya lo trae).

interface Bubble {
  id: string;
  role: "me" | "claude";
  text: string;
  createdAt: number | null;
  change?: { title: string; detail: string } | undefined;
  undoable: boolean;
}

const TITLES: Record<ChatKind, string> = { review: "Review", respond: "Respond", merge: "Merge" };

export interface ChatModel {
  props: ReadonlySignal<ChatProps>;
  open(): () => void;
  send(): Promise<void>;
  undo(): Promise<void>;
  stop(): Promise<void>;
}

function bubblesFrom(chat: ChatInfo): Bubble[] {
  return chat.messages.map((m) => {
    let change: Bubble["change"];
    if (m.changes) {
      const [title = "", ...rest] = m.changes.split("\n");
      change = { title, detail: rest.join("\n") };
    }
    return { id: m.id, role: m.role === "user" ? "me" : "claude", text: m.text, createdAt: parseDate(m.createdAt),
             change, undoable: m.undoable && !m.undone };
  });
}

let localIds = 0;

export function createChatModel(ctx: AppContext, pr: string, kind: ChatKind): ChatModel {
  const { store } = ctx;
  const cached = store.details.value[pr]?.chat;
  const bubbles = signal<Bubble[]>(cached ? bubblesFrom(cached) : []);
  const streaming = signal(false);
  const draft = signal("");
  let remoteBubble: string | null = null;

  const apply = (chat: ChatInfo) => {
    remoteBubble = null;
    bubbles.value = bubblesFrom(chat);
  };
  const append = (id: string, delta: string) => {
    bubbles.value = bubbles.value.map((b) => (b.id === id ? { ...b, text: b.text + delta } : b));
  };
  const refresh = async () => {
    const chat = await perform(ctx, { chatShow: { pr } });
    if (chat) apply(chat);
  };

  const model: ChatModel = {
    props: computed((): ChatProps => {
      const list = bubbles.value;
      const items: ChatItemVM[] = [];
      for (const b of list) {
        if (b.text) items.push(b.role === "me" ? { kind: "mine", id: b.id, text: b.text } : { kind: "claude", id: b.id, text: b.text });
        if (b.change) items.push({ kind: "action", id: b.id, title: b.change.title, detail: b.change.detail, undoable: b.undoable });
      }
      const first = list.find((b) => b.createdAt !== null)?.createdAt ?? null;
      return {
        context: `${shortRef(pr)} · ${TITLES[kind]}`,
        readOnly: kind === "merge",
        timestamp: first === null ? undefined : chatStamp(first, store.minute.value, ctx.locale),
        items,
        typing: streaming.value && (list.at(-1)?.text ?? "") === "",
        draft: draft.value,
        placeholder: kind === "merge" ? "Ask about this PR" : "Message Claude",
        disabled: store.isStale.value || streaming.value,
        onBack: () => ctx.nav.back(),
        onDraft: (text) => (draft.value = text),
        onSend: () => void model.send(),
        onUndo: () => void model.undo(),
      };
    }),
    open() {
      const off = store.onChatDelta(pr, (text) => {
        if (streaming.value) return;
        if (remoteBubble && bubbles.value.some((b) => b.id === remoteBubble)) {
          append(remoteBubble, text);
        } else {
          remoteBubble = `remote-${++localIds}`;
          bubbles.value = [...bubbles.value, { id: remoteBubble, role: "claude", text, createdAt: store.now.value, undoable: false }];
        }
      });
      void refresh();
      return off;
    },
    async send() {
      const text = draft.value.trim();
      if (!text || streaming.value || store.isStale.value) return;
      draft.value = "";
      const mine = `local-${++localIds}`;
      const reply = `local-${++localIds}`;
      const now = store.now.value;
      bubbles.value = [...bubbles.value, { id: mine, role: "me", text, createdAt: now, undoable: false },
                       { id: reply, role: "claude", text: "", createdAt: now, undoable: false }];
      streaming.value = true;
      try {
        const chat = await perform(ctx, { chatSend: { pr, message: text } }, {
          onEvent: (event) => {
            if ("text" in event) append(reply, event.text.delta);
          },
        });
        if (chat) apply(chat);
        else bubbles.value = bubbles.value.filter((b) => !(b.id === reply && b.text === ""));
      } finally {
        streaming.value = false;
      }
    },
    async undo() {
      await undoWithConfirmation(ctx, pr, refresh);
    },
    async stop() {
      await perform(ctx, { chatStop: { pr } });
    },
  };
  return model;
}
