import { b64Decode } from "../crypto/b64";
import type { Bytes } from "../crypto/bytes";
import { mailboxInfo, openEnvelope } from "../crypto/hpke";
import type { CommandEvent, Incompatibility } from "../protocol/appFrames";
import {
  commandName, decidePolicy, decodeActivity, decodeHome, decodePRDetail, decodeResult, GATED_NAMES, parseTopic,
  MAX_TOPICS_PER_SUBSCRIPTION, type AppCommand, type MailboxBlob, type RemoteActivity, type RemoteHome,
  type RemotePRDetail, type ResultOf,
} from "../protocol/commands";
import {
  expectInt, expectObject, expectString, parseISODate, parseJSONBytes, swiftJSON, type JSONValue,
} from "../protocol/json";
import type { RelayMailboxItem, RelayMessage } from "../protocol/relayFrames";
import { displayName } from "../protocol/text";
import { INCOMPATIBLE_MESSAGE } from "../protocol/version";
import { RelayClient, type RelayState, type VisibilitySource, type WebSocketFactory } from "./RelayClient";
import { Session, type PresencePolicy } from "./Session";
import {
  CommandError, RemoteError, systemClock, type Authorize, type Clock, type DeviceKeys, type PairedMac,
} from "./types";

// Lo que usa la UI para hablar con la Mac (R.3 y W.2): el estado del enlace, comandos con sus eventos y la prueba de
// presencia, tópicos, buzón, Web Push y desemparejar. `LiveTransport` lo hace de verdad (RelayClient + Session);
// `FakeTransport` contesta con los JSON que genera la Mac (`app.json`) para los tests de la UI.

export type LinkState =
  | { kind: "unpaired" }
  | { kind: "disconnected" }
  | { kind: "connecting" }
  | { kind: "online" }
  /** `since`: milisegundos (desde cuándo está offline, si el relay lo sabe). */
  | { kind: "macOffline"; since: number | null }
  | { kind: "relayUnreachable"; retryAt: number | null }
  /** 4401/4403 del relay: no prueba nada (M3), no se borra nada. */
  | { kind: "relayRejected"; code: number | null }
  /** 4409: otra ventana de la app se conectó con este dispositivo. */
  | { kind: "replaced" }
  /** `bye(revoked)` de la Mac dentro de la sesión: hay que borrar claves y caché y volver a emparejar. */
  | { kind: "revoked" }
  | { kind: "incompatible"; reason: Incompatibility; message: string };

export type TransportEvent =
  | { type: "state"; state: LinkState }
  /** Llegó un valor nuevo de un tópico: leerlo con `topic(name)`. */
  | { type: "topic"; name: string }
  /** Un pedazo de un chat que no inició este teléfono. */
  | { type: "chatDelta"; pr: string; text: string }
  | { type: "presencePolicy"; policy: PresencePolicy };

export interface SendOptions {
  /** Firma el desafío con la passkey. Solo se usa si el comando lo necesita (`needsPresence`). */
  authorize?: Authorize;
  onEvent?: (event: CommandEvent) => void;
}

export interface PendingCommand {
  id: number;
  /** El `result` de la Mac. Falla con `CommandError` (la Mac contestó un error) o `RemoteError`. */
  result: Promise<JSONValue>;
}

/** La suscripción de Web Push (`PushSubscription.getKey("p256dh")` y `getKey("auth")`). */
export interface WebPushSubscriptionKeys {
  endpoint: string;
  p256dh: Uint8Array;
  auth: Uint8Array;
}

export interface Transport {
  readonly state: LinkState;
  /** El nombre de la Mac (del `hello`, o el del emparejamiento). */
  readonly macName: string | null;
  readonly presencePolicy: PresencePolicy;
  subscribe(listener: (event: TransportEvent) => void): () => void;
  /** Quiere estar conectado (la app en primer plano). */
  start(): void;
  stop(): void;
  /** "Try Again": reintenta ya (también después de `relayRejected`, `replaced` o `incompatible`). */
  retryNow(): void;
  /** El comando pide Face ID: gated y la Mac exige presencia para este dispositivo. */
  needsPresence(command: AppCommand): boolean;
  send(command: AppCommand, options?: SendOptions): Promise<PendingCommand>;
  /** `send` + esperar el resultado, con los campos obligatorios comprobados. */
  run<C extends AppCommand>(command: C, options?: SendOptions): Promise<ResultOf<C>>;
  /** Los eventos de un pedido en curso (repite los que ya llegaron). */
  events(id: number, listener: (event: CommandEvent) => void): () => void;
  /** Reemplaza el conjunto de tópicos (se vuelve a mandar en cada sesión nueva). */
  subscribeTopics(topics: string[]): void;
  /** El último valor de un tópico. */
  topic(name: "home"): RemoteHome | undefined;
  topic(name: "activity"): RemoteActivity | undefined;
  topic(name: string): RemotePRDetail | RemoteHome | RemoteActivity | undefined;
  registerWebPush(subscription: WebPushSubscriptionKeys): void;
  /** Lee el buzón del relay y abre lo que se pueda (lo que no autentica, vuelve atrás o es viejo se ignora). */
  mailbox(): Promise<MailboxBlob[]>;
  /** "Unpair this iPhone": avisa a la Mac y corta. Borrar claves y caché es de quien llama. */
  unpair(): Promise<void>;
}

/** El valor decodificado de un tópico, o `undefined` si no se entiende. */
function decodeTopic(name: string, data: unknown): RemoteHome | RemoteActivity | RemotePRDetail | undefined {
  const topic = parseTopic(name);
  try {
    if (topic?.kind === "home") return decodeHome(data);
    if (topic?.kind === "activity") return decodeActivity(data);
    if (topic?.kind === "pr") return decodePRDetail(data);
  } catch {
    // Un tópico roto no rompe la sesión: se queda el valor anterior.
  }
  return undefined;
}

function normalizedTopics(topics: string[]): string[] {
  return [...new Set(topics.filter((t) => parseTopic(t) !== null))].slice(0, MAX_TOPICS_PER_SUBSCRIPTION);
}

class Emitter {
  readonly #listeners = new Set<(event: TransportEvent) => void>();

  subscribe(listener: (event: TransportEvent) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  emit(event: TransportEvent): void {
    for (const listener of [...this.#listeners]) {
      try {
        listener(event);
      } catch (error) {
        console.error(error);
      }
    }
  }
}

interface EventLog {
  events: CommandEvent[];
  listeners: Set<(event: CommandEvent) => void>;
}

// --- Buzón ---

/** Lo que el relay guarda un blob: uno más viejo no puede ser legítimo (MailboxBlob.maxAge). */
export const MAILBOX_MAX_AGE_MS = 7 * 24 * 3_600_000;
/** Tolerancia de reloj para un `createdAt` en el futuro. */
export const MAILBOX_MAX_SKEW_MS = 10 * 60_000;

/** Abre un blob del buzón (MailboxBlob.open): misma ranura que el `info`, `rev` ≥ el último visto y no más viejo que
 *  7 días (ni más de 10 min en el futuro). Tira si algo no cierra. */
export function openMailboxItem(item: RelayMailboxItem, paired: PairedMac, devicePush: Uint8Array, minimumRev: number,
                                now: number): MailboxBlob {
  const plaintext = openEnvelope(item.b, devicePush, paired.macSeal,
                                 mailboxInfo(paired.accountId, paired.deviceId, item.slot));
  const c = expectObject(parseJSONBytes(plaintext), "mailbox blob");
  const slot = expectString(c.slot, "slot");
  const rev = expectInt(c.rev, "rev");
  const createdAt = expectString(c.createdAt, "createdAt");
  const created = parseISODate(createdAt);
  const data = b64Decode(expectString(c.data, "data"));
  if (slot !== item.slot) throw new Error("mailbox: wrong slot");
  if (rev < minimumRev) throw new Error("mailbox: rollback");
  if (created === null || now - created > MAILBOX_MAX_AGE_MS || created - now > MAILBOX_MAX_SKEW_MS) {
    throw new Error("mailbox: stale");
  }
  return { slot, rev, createdAt, data };
}

// --- La de verdad ---

export interface LiveTransportOptions {
  paired: PairedMac;
  keys: DeviceKeys;
  /** `appVersion` del `hello` ("web-0.1.0"). */
  appVersion: string;
  deviceName: string;
  webSocket?: WebSocketFactory;
  clock?: Clock;
  /** `null` sin ciclo de vida de la página (tests). Por defecto el `document`. */
  visibility?: VisibilitySource | null;
  /** Relay local de los tests. */
  insecure?: boolean;
  random?: () => number;
  handshakeTimeoutMs?: number;
  requestTimeoutMs?: number;
  /** El último `rev` del buzón por ranura, guardado en la caché (revisión M2). */
  mailboxRevisions?: Record<string, number>;
  /** Solo para los vectores: `sid` y efímera de la próxima sesión. */
  sessionSeed?: () => { sid?: string; fixedEphemeral?: Bytes };
}

const SESSION_BACKOFF_MS = [0, 1000, 2000, 4000, 8000, 16_000, 30_000];

export class LiveTransport implements Transport {
  readonly #options: LiveTransportOptions;
  readonly #clock: Clock;
  readonly #relay: RelayClient;
  readonly #emitter = new Emitter();
  #state: LinkState = { kind: "disconnected" };
  #session: Session | null = null;
  #opening: Promise<Session> | null = null;
  #sessionAttempt = 0;
  #sessionTimer: unknown = null;
  #relayKind: RelayState["kind"] = "idle";
  #macName: string | null;
  #policy: PresencePolicy = { requirePresence: true, gated: [...GATED_NAMES] };
  #topics: string[] = [];
  readonly #topicValues = new Map<string, RemoteHome | RemoteActivity | RemotePRDetail>();
  readonly #eventLogs = new Map<number, EventLog>();
  #webpush: WebPushSubscriptionKeys | null = null;
  #mailboxRevs: Record<string, number>;
  #mailboxWaiter: ((items: RelayMailboxItem[] | RemoteError) => void) | null = null;

  constructor(options: LiveTransportOptions) {
    this.#options = options;
    this.#clock = options.clock ?? systemClock;
    this.#macName = options.paired.macName;
    this.#mailboxRevs = { ...options.mailboxRevisions };
    const { paired, keys } = options;
    this.#relay = new RelayClient({
      host: paired.relayHost, credential: { kind: "signed", account: paired.accountId, client: paired.deviceId,
                                            key: keys.relay },
      clock: this.#clock, insecure: options.insecure ?? false,
      ...(options.webSocket ? { webSocket: options.webSocket } : {}),
      ...(options.visibility !== undefined ? { visibility: options.visibility } : {}),
      ...(options.random ? { random: options.random } : {}),
    });
    this.#relay.subscribe((state) => this.#relayChanged(state));
    this.#relay.onMessage((message) => this.#relayMessage(message));
  }

  get state(): LinkState {
    return this.#state;
  }

  get macName(): string | null {
    return this.#macName;
  }

  get presencePolicy(): PresencePolicy {
    return this.#policy;
  }

  /** El último `rev` del buzón por ranura: guardarlo en la caché para no aceptar un estado viejo al reabrir. */
  get mailboxRevisions(): Record<string, number> {
    return { ...this.#mailboxRevs };
  }

  subscribe(listener: (event: TransportEvent) => void): () => void {
    return this.#emitter.subscribe(listener);
  }

  start(): void {
    if (this.#terminal) return;
    this.#relay.start();
  }

  stop(): void {
    this.#relay.stop();
    this.#dropSession(new RemoteError("sessionClosed"));
    if (!this.#terminal) this.#setState({ kind: "disconnected" });
  }

  retryNow(): void {
    if (this.#state.kind === "revoked" || this.#state.kind === "unpaired") return;
    if (this.#state.kind === "incompatible") this.#setState({ kind: "disconnected" });
    this.#sessionAttempt = 0;
    const relay = this.#relay.state;
    if (relay.kind === "ready") {
      if (relay.mac === "online" && !this.#session?.isOpen) void this.#openSession().catch(() => {});
    } else {
      this.#relay.retryNow();
    }
  }

  needsPresence(command: AppCommand): boolean {
    return decidePolicy(command) === "gated" && this.#policy.requirePresence;
  }

  async send(command: AppCommand, options: SendOptions = {}): Promise<PendingCommand> {
    const needsPresence = this.needsPresence(command);
    if (needsPresence && !options.authorize) throw new RemoteError("presenceRequired");
    // Una conexión en duda (recién vuelta del segundo plano, o callada hace rato) se comprueba antes de usarla: un
    // comando gated no espera (Face ID tiene que pedirse ya) y falla enseguida; los demás esperan el `pong` o la
    // conexión nueva. Si no, el pedido podría irse por un WebSocket muerto y esperar el minuto entero.
    if (this.#relay.stale) {
      this.#relay.probe();
      if (needsPresence) throw this.#unavailable() ?? new RemoteError("connecting");
      await this.#relay.settled();
    } else {
      // Mientras sale el pedido, un `ping`: si la red cambió hace un momento, se nota en 5 s y no en 60.
      this.#relay.probe();
    }
    // Face ID tiene que pedirse dentro del toque: Safari no muestra el aviso de WebAuthn después de un `await`. Con la
    // sesión abierta, `authorize` corre sincrónico desde acá (sin `await` antes de `credentials.get`); sin sesión, un
    // comando gated no espera a abrirla para pedirlo: falla y la sesión se abre para el próximo toque.
    let session = this.#session?.isOpen ? this.#session : null;
    if (!session && needsPresence) {
      this.#ensureSession().catch(() => {});
      throw this.#unavailable() ?? new RemoteError("connecting");
    }
    session ??= await this.#ensureSession();
    const log: EventLog = { events: [], listeners: new Set() };
    const sent = await session.request(command, {
      ...(needsPresence ? { authorize: options.authorize! } : {}),
      onEvent: (event) => {
        log.events.push(event);
        options.onEvent?.(event);
        for (const listener of [...log.listeners]) listener(event);
      },
    });
    this.#eventLogs.set(sent.id, log);
    const result = sent.response.then(
      (response) => {
        this.#eventLogs.delete(sent.id);
        if (response.error || response.ok === false) {
          throw new CommandError(response.error ?? { code: "failed", message: "The command failed." });
        }
        return response.result ?? null;
      },
      (error: unknown) => {
        this.#eventLogs.delete(sent.id);
        throw error;
      },
    );
    result.catch(() => {});
    return { id: sent.id, result };
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
    this.#topics = normalizedTopics(topics);
    if (this.#session?.isOpen) this.#session.subscribe(this.#topics);
  }

  topic(name: "home"): RemoteHome | undefined;
  topic(name: "activity"): RemoteActivity | undefined;
  topic(name: string): RemotePRDetail | RemoteHome | RemoteActivity | undefined;
  topic(name: string): RemotePRDetail | RemoteHome | RemoteActivity | undefined {
    return this.#topicValues.get(name);
  }

  registerWebPush(subscription: WebPushSubscriptionKeys): void {
    this.#webpush = subscription;
    if (this.#relay.state.kind === "ready") this.#sendWebPush();
  }

  async mailbox(): Promise<MailboxBlob[]> {
    if (this.#relay.state.kind !== "ready") throw new RemoteError("relayUnreachable");
    const items = await new Promise<RelayMailboxItem[] | RemoteError>((resolve) => {
      this.#mailboxWaiter?.(new RemoteError("timeout"));
      const timer = this.#clock.setTimeout(() => {
        if (this.#mailboxWaiter === waiter) this.#mailboxWaiter = null;
        resolve(new RemoteError("timeout"));
      }, this.#options.handshakeTimeoutMs ?? 15_000);
      const waiter = (value: RelayMailboxItem[] | RemoteError) => {
        this.#clock.clearTimeout(timer);
        resolve(value);
      };
      this.#mailboxWaiter = waiter;
      try {
        this.#relay.send({ t: "mbox.get" });
      } catch {
        this.#mailboxWaiter = null;
        waiter(new RemoteError("relayUnreachable"));
      }
    });
    if (items instanceof RemoteError) throw items;
    const blobs: MailboxBlob[] = [];
    for (const item of items) {
      try {
        const blob = openMailboxItem(item, this.#options.paired, this.#options.keys.push,
                                     this.#mailboxRevs[item.slot] ?? 0, this.#clock.now());
        this.#mailboxRevs[item.slot] = blob.rev;
        blobs.push(blob);
      } catch {
        // Lo que no abre, vuelve atrás o es viejo se ignora (el estado en vivo igual llega).
      }
    }
    return blobs;
  }

  async unpair(): Promise<void> {
    this.#session?.sendUnpair();
    this.#relay.stop();
    this.#dropSession(new RemoteError("notPaired"));
    this.#topics = [];
    this.#topicValues.clear();
    this.#setState({ kind: "unpaired" });
  }

  // --- Por dentro ---

  get #terminal(): boolean {
    return this.#state.kind === "revoked" || this.#state.kind === "unpaired";
  }

  #setState(state: LinkState): void {
    if (this.#terminal) return;
    this.#state = state;
    this.#emitter.emit({ type: "state", state });
  }

  #relayChanged(state: RelayState): void {
    const previous = this.#relayKind;
    this.#relayKind = state.kind;
    switch (state.kind) {
      case "idle":
        this.#dropSession(new RemoteError("sessionClosed"));
        if (this.#state.kind !== "incompatible") this.#setState({ kind: "disconnected" });
        return;
      case "connecting":
        // Una conexión nueva (también la que reemplaza enseguida a una que murió sin avisar): la sesión de la
        // anterior ya no sirve, y lo que esperaba en ella falla ya.
        this.#dropSession(new RemoteError("relayUnreachable"));
        if (this.#state.kind !== "incompatible") this.#setState({ kind: "connecting" });
        return;
      case "ready":
        // Ya estaba conectado: es un cambio de presencia de la Mac, que maneja `#relayMessage`.
        if (previous === "ready") return;
        if (this.#webpush) this.#sendWebPush();
        if (state.mac === "online") {
          if (!this.#session && !this.#opening && this.#state.kind !== "incompatible") {
            void this.#openSession().catch(() => {});
          }
        } else {
          this.#dropSession(new RemoteError("macOffline"));
          this.#setState({ kind: "macOffline", since: state.since * 1000 });
        }
        return;
      case "unreachable":
        this.#dropSession(new RemoteError("relayUnreachable"));
        this.#setState({ kind: "relayUnreachable", retryAt: state.retryAt });
        return;
      case "rejected":
        this.#dropSession(new RemoteError("relayRejected"));
        this.#setState({ kind: "relayRejected", code: state.code });
        return;
      case "replaced":
        this.#dropSession(new RemoteError("replaced"));
        this.#setState({ kind: "replaced" });
        return;
    }
  }

  #relayMessage(message: RelayMessage): void {
    switch (message.t) {
      case "recv":
        if (message.from === "mac" && this.#session && message.sid === this.#session.sid) {
          this.#session.receive(message.b);
        }
        return;
      case "presence":
        if (message.mac === "online") {
          // Una Mac que volvió a conectarse sin pasar por offline no tiene nuestra sesión: se rehace (M3).
          this.#dropSession(new RemoteError("sessionClosed"));
          this.#sessionAttempt = 0;
          if (this.#state.kind !== "incompatible") void this.#openSession().catch(() => {});
        } else if (message.mac === "offline") {
          this.#dropSession(new RemoteError("macOffline"));
          this.#setState({ kind: "macOffline", since: message.since === undefined ? null : message.since * 1000 });
        }
        return;
      case "undeliverable":
        if (this.#session && message.sid === this.#session.sid) {
          this.#dropSession(new RemoteError("macOffline"));
          this.#setState({ kind: "macOffline", since: null });
        }
        return;
      case "mbox":
        this.#mailboxWaiter?.(message.items);
        this.#mailboxWaiter = null;
        return;
      default:
        return;
    }
  }

  #openSession(): Promise<Session> {
    if (this.#opening) return this.#opening;
    if (this.#session?.isOpen) return Promise.resolve(this.#session);
    if (this.#sessionTimer !== null) this.#clock.clearTimeout(this.#sessionTimer);
    this.#sessionTimer = null;
    const { paired, keys } = this.#options;
    const seed = this.#options.sessionSeed?.() ?? {};
    const session = new Session({
      account: paired.accountId, device: paired.deviceId, deviceStatic: keys.noise, macStatic: paired.macStatic,
      appVersion: this.#options.appVersion, deviceName: this.#options.deviceName, clock: this.#clock,
      send: (message) => this.#relay.send(message),
      ...(this.#options.handshakeTimeoutMs !== undefined ? { handshakeTimeoutMs: this.#options.handshakeTimeoutMs } : {}),
      ...(this.#options.requestTimeoutMs !== undefined ? { requestTimeoutMs: this.#options.requestTimeoutMs } : {}),
      ...seed,
    }, {
      onState: (update) => {
        const value = decodeTopic(update.topic, update.data);
        if (value === undefined) return;
        this.#topicValues.set(update.topic, value);
        this.#emitter.emit({ type: "topic", name: update.topic });
      },
      onChatDelta: (pr, text) => this.#emitter.emit({ type: "chatDelta", pr, text }),
      onPresencePolicy: (policy) => {
        this.#policy = policy;
        this.#emitter.emit({ type: "presencePolicy", policy });
      },
      onClose: (error) => this.#sessionClosed(session, error),
    });
    this.#session = session;
    this.#setState({ kind: "connecting" });
    const opening = session.open().then(
      (hello) => {
        if (this.#opening === opening) this.#opening = null;
        if (this.#session !== session) throw new RemoteError("sessionClosed");
        this.#sessionAttempt = 0;
        const name = hello.macName === undefined ? "" : displayName(hello.macName);
        if (name) this.#macName = name;
        this.#setState({ kind: "online" });
        if (this.#topics.length > 0) session.subscribe(this.#topics);
        return session;
      },
      (error: unknown) => {
        if (this.#opening === opening) this.#opening = null;
        const remote = error instanceof RemoteError ? error : new RemoteError("handshakeFailed");
        if (this.#session === session) {
          this.#session = null;
          this.#sessionFailed(remote);
        }
        throw remote;
      },
    );
    this.#opening = opening;
    return opening;
  }

  #sessionClosed(session: Session, error: RemoteError): void {
    if (this.#session !== session) return;
    this.#session = null;
    this.#sessionFailed(error);
  }

  /** La sesión no abrió o se cayó con el relay todavía conectado. */
  #sessionFailed(error: RemoteError): void {
    if (error.code === "revoked") {
      this.#setState({ kind: "revoked" });
      this.#relay.stop();
      return;
    }
    if (error.code === "incompatible") {
      const reason = error.incompatibility ?? "updateMac";
      this.#setState({ kind: "incompatible", reason, message: INCOMPATIBLE_MESSAGE[reason] });
      return;
    }
    const relay = this.#relay.state;
    if (relay.kind !== "ready" || relay.mac !== "online") return;
    // Otra sesión: enseguida la primera vez, después con backoff (una Mac que no reconoce al teléfono no contesta).
    const delay = SESSION_BACKOFF_MS[Math.min(this.#sessionAttempt, SESSION_BACKOFF_MS.length - 1)]!;
    this.#sessionAttempt++;
    this.#setState(delay === 0 ? { kind: "connecting" } : { kind: "disconnected" });
    this.#sessionTimer = this.#clock.setTimeout(() => {
      this.#sessionTimer = null;
      void this.#openSession().catch(() => {});
    }, delay);
  }

  #dropSession(error: RemoteError): void {
    if (this.#sessionTimer !== null) this.#clock.clearTimeout(this.#sessionTimer);
    this.#sessionTimer = null;
    const session = this.#session;
    this.#session = null;
    this.#opening = null;
    session?.close(error);
    this.#mailboxWaiter?.(error);
    this.#mailboxWaiter = null;
  }

  /** Por qué no se puede abrir una sesión ahora mismo (revocado, incompatible, la Mac offline), o `null`. */
  #unavailable(): RemoteError | null {
    switch (this.#state.kind) {
      case "revoked":
        return new RemoteError("revoked");
      case "unpaired":
        return new RemoteError("notPaired");
      case "incompatible":
        return new RemoteError("incompatible", this.#state.reason);
      default:
        break;
    }
    const relay = this.#relay.state;
    if (relay.kind === "ready" && relay.mac === "offline") return new RemoteError("macOffline", undefined, relay.since * 1000);
    return null;
  }

  async #ensureSession(): Promise<Session> {
    if (this.#session?.isOpen) return this.#session;
    const unavailable = this.#unavailable();
    if (unavailable) throw unavailable;
    const relay = this.#relay.state;
    if (relay.kind === "ready") return this.#openSession();
    if (relay.kind === "idle") this.#relay.start();
    else if (relay.kind !== "connecting") this.#relay.retryNow();
    // Espera a que el relay conteste (y la sesión abra) o a que falle.
    return new Promise<Session>((resolve, reject) => {
      const unsubscribe = this.subscribe((event) => {
        if (event.type !== "state") return;
        const done = (fn: () => void) => {
          unsubscribe();
          this.#clock.clearTimeout(timer);
          fn();
        };
        const state = event.state;
        if (state.kind === "online" && this.#session?.isOpen) done(() => resolve(this.#session!));
        else if (state.kind === "macOffline") done(() => reject(new RemoteError("macOffline", undefined, state.since ?? undefined)));
        else if (state.kind === "relayUnreachable") done(() => reject(new RemoteError("relayUnreachable")));
        else if (state.kind === "relayRejected") done(() => reject(new RemoteError("relayRejected")));
        else if (state.kind === "replaced") done(() => reject(new RemoteError("replaced")));
        else if (state.kind === "revoked") done(() => reject(new RemoteError("revoked")));
        else if (state.kind === "incompatible") done(() => reject(new RemoteError("incompatible", state.reason)));
        else if (state.kind === "disconnected") done(() => reject(new RemoteError("handshakeFailed")));
      });
      const timer = this.#clock.setTimeout(() => {
        unsubscribe();
        reject(new RemoteError("handshakeFailed"));
      }, 2 * (this.#options.handshakeTimeoutMs ?? 15_000));
    });
  }

  #sendWebPush(): void {
    const sub = this.#webpush!;
    try {
      this.#relay.send({ t: "webpush", endpoint: sub.endpoint, p256dh: Uint8Array.from(sub.p256dh),
                         auth: Uint8Array.from(sub.auth) });
    } catch {
      // Se vuelve a mandar en la próxima conexión.
    }
  }
}

// --- La de prueba ---

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
