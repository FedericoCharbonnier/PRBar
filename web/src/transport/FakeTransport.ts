import type { CommandEvent } from "../protocol/appFrames";
import {
  commandName, decidePolicy, decodeResult, GATED_NAMES, type AppCommand, type MailboxBlob, type RemoteActivity,
  type RemoteHome, type RemotePRDetail, type ResultOf,
} from "../protocol/commands";
import { swiftJSON, type JSONValue } from "../protocol/json";
import type { PresencePolicy } from "./Session";
import {
  decodeTopic, Emitter, normalizedTopics, type EventLog, type LinkState, type PendingCommand, type SendOptions, type Transport,
  type TransportEvent, type WebPushSubscriptionKeys,
} from "./Transport";
import { CommandError, RemoteError } from "./types";

// Un `Transport` de mentira para los tests de la UI (en su propio módulo: la app nunca lo importa, así no puede
// terminar en el build).

/** Lo que usa `FakeTransport`: la forma de `web/test/fixtures/app.json`. */
export interface FakeTransportFixture {
  commands: { name: string; text: string; response: unknown; events?: unknown[] }[];
  topics: { topic: string; text: string }[];
}

/** Un `Transport` para los tests de la UI y la demo: contesta con las respuestas de `app.json` (la primera cuyo
 *  `text` coincide exacto, o la primera con ese nombre), emite sus eventos y sirve los tópicos de ahí. */
export class FakeTransport implements Transport {
  /** Lo que mandó la UI, en orden; `presence` = se firmó el desafío. */
  readonly sent: { command: AppCommand; presence: boolean }[] = [];
  readonly webPush: WebPushSubscriptionKeys[] = [];
  topics: string[] = [];
  mailboxBlobs: MailboxBlob[] = [];
  macName: string | null = "Mac";
  presencePolicy: PresencePolicy = { requirePresence: true, gated: [...GATED_NAMES] };
  readonly #emitter = new Emitter();
  readonly #fixture: FakeTransportFixture;
  readonly #overrides = new Map<string, (command: AppCommand) => JSONValue | CommandError | RemoteError>();
  readonly #topicValues = new Map<string, RemoteHome | RemoteActivity | RemotePRDetail>();
  readonly #eventLogs = new Map<number, EventLog>();
  #state: LinkState;
  #nextId = 0;

  constructor(fixture: FakeTransportFixture = { commands: [], topics: [] }, state: LinkState = { kind: "online" }) {
    this.#fixture = fixture;
    this.#state = state;
    for (const { topic, text } of fixture.topics) {
      const value = decodeTopic(topic, JSON.parse(text));
      if (value !== undefined) this.#topicValues.set(topic, value);
    }
  }

  get state(): LinkState {
    return this.#state;
  }

  subscribe(listener: (event: TransportEvent) => void): () => void {
    return this.#emitter.subscribe(listener);
  }

  start(): void {}
  stop(): void {}
  retryNow(): void {}

  needsPresence(command: AppCommand): boolean {
    return decidePolicy(command) === "gated" && this.presencePolicy.requirePresence;
  }

  // --- Para los tests ---

  setState(state: LinkState): void {
    this.#state = state;
    this.#emitter.emit({ type: "state", state });
  }

  setTopic(name: string, data: unknown): void {
    const value = decodeTopic(name, data);
    if (value === undefined) throw new Error(`bad topic ${name}`);
    this.#topicValues.set(name, value);
    this.#emitter.emit({ type: "topic", name });
  }

  emitChatDelta(pr: string, text: string): void {
    this.#emitter.emit({ type: "chatDelta", pr, text });
  }

  setPresencePolicy(policy: PresencePolicy): void {
    this.presencePolicy = policy;
    this.#emitter.emit({ type: "presencePolicy", policy });
  }

  /** Contesta `name` con lo que devuelva `handler` (un `result`, o un error para fallar). */
  respond(name: string, handler: (command: AppCommand) => JSONValue | CommandError | RemoteError): void {
    this.#overrides.set(name, handler);
  }

  // --- Transport ---

  async send(command: AppCommand, options: SendOptions = {}): Promise<PendingCommand> {
    if (this.#state.kind !== "online") throw this.#stateError();
    const presence = this.needsPresence(command);
    if (presence && !options.authorize) throw new RemoteError("presenceRequired");
    if (presence) await options.authorize!(new Uint8Array(32));
    this.sent.push({ command, presence });
    const id = ++this.#nextId;
    const name = commandName(command);
    const text = swiftJSON(command);
    const sample = this.#fixture.commands.find((c) => c.text === text)
      ?? this.#fixture.commands.find((c) => c.name === name);
    const log: EventLog = { events: [], listeners: new Set() };
    this.#eventLogs.set(id, log);
    const result = (async (): Promise<JSONValue> => {
      await Promise.resolve();
      for (const raw of sample?.events ?? []) {
        const event = (raw as { event: CommandEvent }).event;
        log.events.push(event);
        options.onEvent?.(event);
        for (const listener of [...log.listeners]) listener(event);
      }
      this.#eventLogs.delete(id);
      const override = this.#overrides.get(name);
      if (override) {
        const value = override(command);
        if (value instanceof Error) throw value;
        return value;
      }
      const response = sample?.response as { ok?: boolean; result?: JSONValue; error?: { code: string; message: string } }
        | undefined;
      if (!response) return { ok: true };
      if (response.error) throw new CommandError(response.error);
      return response.result ?? null;
    })();
    result.catch(() => {});
    return { id, result };
  }

  async run<C extends AppCommand>(command: C, options?: SendOptions): Promise<ResultOf<C>> {
    const pending = await this.send(command, options);
    return decodeResult(commandName(command), await pending.result) as ResultOf<C>;
  }

  events(id: number, listener: (event: CommandEvent) => void): () => void {
    const log = this.#eventLogs.get(id);
    if (!log) return () => {};
    for (const event of log.events) listener(event);
    log.listeners.add(listener);
    return () => log.listeners.delete(listener);
  }

  subscribeTopics(topics: string[]): void {
    this.topics = normalizedTopics(topics);
  }

  topic(name: "home"): RemoteHome | undefined;
  topic(name: "activity"): RemoteActivity | undefined;
  topic(name: string): RemotePRDetail | RemoteHome | RemoteActivity | undefined;
  topic(name: string): RemotePRDetail | RemoteHome | RemoteActivity | undefined {
    return this.#topicValues.get(name);
  }

  registerWebPush(subscription: WebPushSubscriptionKeys): void {
    this.webPush.push(subscription);
  }

  async mailbox(): Promise<MailboxBlob[]> {
    return this.mailboxBlobs;
  }

  async unpair(): Promise<void> {
    this.setState({ kind: "unpaired" });
  }

  #stateError(): RemoteError {
    switch (this.#state.kind) {
      case "macOffline":
        return new RemoteError("macOffline", undefined, this.#state.since ?? undefined);
      case "revoked":
        return new RemoteError("revoked");
      case "unpaired":
        return new RemoteError("notPaired");
      case "relayRejected":
        return new RemoteError("relayRejected");
      case "replaced":
        return new RemoteError("replaced");
      case "incompatible":
        return new RemoteError("incompatible", this.#state.reason);
      default:
        return new RemoteError("relayUnreachable");
    }
  }
}
