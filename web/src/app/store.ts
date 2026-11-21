import { computed, signal, type ReadonlySignal, type Signal } from "@preact/signals";
import { decodeHome, parseTopic, prTopic, type RemoteActivity, type RemoteHome, type RemotePRDetail } from "../protocol/commands";
import { parseJSONBytes } from "../protocol/json";
import type { Cache } from "../store/cache";
import type { LinkState, Transport, TransportEvent } from "../transport/Transport";
import { systemClock, type Clock } from "../transport/types";

// Lo que el teléfono sabe de la Mac (AppStore + RemoteConnection de la app nativa, R.3): el estado del enlace, `home`,
// los detalles de PR, `activity`, "Last updated"; se alimenta de los tópicos del transporte y del buzón, y escribe la
// caché. Las pantallas retienen sus tópicos mientras están visibles (`activity` solo con Activity abierta).

export interface AppStoreOptions {
  transport: Transport;
  cache?: Cache | null;
  clock?: Clock;
  /** `bye(revoked)` de la Mac dentro de la sesión: hay que borrar claves y caché (lo hace quien arma el store). */
  onRevoked?: () => void;
  /** El ícono de la app sigue el `badgeCount` de `home` (R.7). */
  setBadge?: (count: number) => void;
}

/** "Last updated" de un `home` del buzón es cuándo lo escribió la Mac; uno de más de 7 días no se muestra. */
const MAILBOX_MAX_AGE_MS = 7 * 24 * 3_600_000;

export class AppStore {
  readonly transport: Transport;
  readonly link = signal<LinkState>({ kind: "disconnected" });
  readonly macName = signal<string | null>(null);
  readonly requirePresence = signal(true);
  readonly home = signal<RemoteHome | null>(null);
  /** Milisegundos: cuándo la Mac mandó (o el buzón trajo) `home`. */
  readonly lastUpdated = signal<number | null>(null);
  readonly details = signal<Record<string, RemotePRDetail>>({});
  readonly activity = signal<RemoteActivity | null>(null);
  /** Lo cacheado o sin conexión se ve en gris y las acciones se apagan. */
  readonly isStale: ReadonlySignal<boolean> = computed(() => this.link.value.kind !== "online");
  /** Reloj para las edades y cronómetros (lo avanza el shell cada segundo). */
  readonly now: Signal<number>;

  readonly #cache: Cache | null;
  readonly #clock: Clock;
  readonly #options: AppStoreOptions;
  readonly #topicCounts = new Map<string, number>();
  readonly #chatHandlers = new Map<string, (text: string) => void>();
  #unsubscribe: (() => void) | null = null;

  constructor(options: AppStoreOptions) {
    this.#options = options;
    this.transport = options.transport;
    this.#cache = options.cache ?? null;
    this.#clock = options.clock ?? systemClock;
    this.now = signal(this.#clock.now());
    this.link.value = options.transport.state;
    this.macName.value = options.transport.macName;
    this.requirePresence.value = options.transport.presencePolicy.requirePresence;
  }

  /** Empieza a escuchar al transporte. Una vez. */
  attach(): void {
    if (this.#unsubscribe) return;
    this.#unsubscribe = this.transport.subscribe((event) => this.handle(event));
    this.transport.subscribeTopics(this.topics);
    // Lo que el transporte ya tenía (FakeTransport, o un tópico que llegó antes de montar).
    for (const topic of this.topics) this.#readTopic(topic);
  }

  detach(): void {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
  }

  /** La caché al arrancar: el último `home` (en gris hasta que conecte). */
  async loadCache(): Promise<void> {
    if (!this.#cache) return;
    try {
      const cached = await this.#cache.loadHome();
      if (cached && this.home.value === null) {
        this.home.value = cached.home;
        this.lastUpdated.value = cached.updatedAt;
      }
    } catch {
      // Sin caché se arranca vacío.
    }
  }

  tick(): void {
    this.now.value = this.#clock.now();
  }

  // --- Tópicos ---

  /** Los tópicos suscritos: siempre `home`, más los que retienen las pantallas visibles. */
  get topics(): string[] {
    return ["home", ...[...this.#topicCounts.keys()].filter((t) => t !== "home").sort()];
  }

  retain(topic: string): void {
    const count = (this.#topicCounts.get(topic) ?? 0) + 1;
    this.#topicCounts.set(topic, count);
    if (count === 1) {
      this.transport.subscribeTopics(this.topics);
      this.#readTopic(topic);
      const parsed = parseTopic(topic);
      if (parsed?.kind === "pr" && !this.details.value[parsed.id]) void this.#loadCachedPR(parsed.id);
    }
  }

  release(topic: string): void {
    const count = this.#topicCounts.get(topic);
    if (count === undefined) return;
    if (count <= 1) this.#topicCounts.delete(topic);
    else this.#topicCounts.set(topic, count - 1);
    if (!this.#topicCounts.has(topic)) this.transport.subscribeTopics(this.topics);
  }

  /** El detalle de un PR (en memoria; la caché se carga al retener su tópico). */
  detail(id: string): RemotePRDetail | undefined {
    return this.details.value[id];
  }

  /** El PR en `home` (o en su detalle). */
  prInfo(id: string) {
    return this.details.value[id]?.pr ?? this.home.value?.prs.find((p) => p.id === id);
  }

  /** El nombre visible de un login, si algún PR lo trae (`authorName`). */
  displayName(login: string): string {
    return this.home.value?.prs.find((p) => p.author === login && p.authorName)?.authorName ?? login;
  }

  /** `true` si el PR es de la pestaña My PRs. */
  isMine(id: string): boolean {
    const pr = this.prInfo(id);
    if (pr?.tab) return pr.tab === "mine";
    return pr?.section === "myFeedback" || pr?.section === "readyToMerge" || pr?.section === "waitingForReview";
  }

  // --- Chat empezado en la Mac ---

  onChatDelta(pr: string, handler: (text: string) => void): () => void {
    this.#chatHandlers.set(pr, handler);
    return () => {
      if (this.#chatHandlers.get(pr) === handler) this.#chatHandlers.delete(pr);
    };
  }

  // --- Eventos ---

  handle(event: TransportEvent): void {
    switch (event.type) {
      case "state":
        this.#linkChanged(event.state);
        return;
      case "topic":
        this.#readTopic(event.name);
        return;
      case "chatDelta":
        this.#chatHandlers.get(event.pr)?.(event.text);
        return;
      case "presencePolicy":
        this.requirePresence.value = event.policy.requirePresence;
        return;
    }
  }

  #linkChanged(state: LinkState): void {
    this.link.value = state;
    if (this.transport.macName) this.macName.value = this.transport.macName;
    switch (state.kind) {
      case "online":
        this.requirePresence.value = this.transport.presencePolicy.requirePresence;
        this.transport.subscribeTopics(this.topics);
        return;
      case "macOffline":
        void this.fetchMailbox();
        return;
      case "revoked":
        this.wipe();
        this.#options.onRevoked?.();
        return;
      default:
        return;
    }
  }

  /** El `home` del buzón, si es más nuevo que el de la pantalla (P.16 M2). */
  async fetchMailbox(): Promise<void> {
    let blobs;
    try {
      blobs = await this.transport.mailbox();
    } catch {
      return;
    }
    const revisions = (this.transport as { mailboxRevisions?: Record<string, number> }).mailboxRevisions;
    if (revisions && this.#cache) void this.#cache.saveMailboxRevisions(revisions).catch(() => {});
    const blob = blobs.filter((b) => b.slot === "home" && b.data.length > 0).sort((a, b) => b.rev - a.rev)[0];
    if (!blob) return;
    const created = Date.parse(blob.createdAt);
    if (Number.isNaN(created) || this.#clock.now() - created > MAILBOX_MAX_AGE_MS) return;
    if (this.lastUpdated.value !== null && created <= this.lastUpdated.value) return;
    let home: RemoteHome;
    try {
      home = decodeHome(parseJSONBytes(blob.data));
    } catch {
      return;
    }
    this.#setHome(home, created);
  }

  #readTopic(name: string): void {
    const topic = parseTopic(name);
    if (!topic) return;
    const value = this.transport.topic(name);
    if (value === undefined) return;
    const now = this.#clock.now();
    switch (topic.kind) {
      case "home":
        this.#setHome(value as RemoteHome, now);
        return;
      case "activity":
        this.activity.value = value as RemoteActivity;
        return;
      case "pr":
        this.details.value = { ...this.details.value, [topic.id]: value as RemotePRDetail };
        void this.#cache?.savePR(topic.id, value as RemotePRDetail, now).catch(() => {});
        return;
    }
  }

  #setHome(home: RemoteHome, at: number): void {
    this.home.value = home;
    this.lastUpdated.value = at;
    void this.#cache?.saveHome(home, at).catch(() => {});
    this.#options.setBadge?.(home.status.badgeCount);
  }

  async #loadCachedPR(id: string): Promise<void> {
    try {
      const cached = await this.#cache?.loadPR(id);
      if (cached && !this.details.value[id]) this.details.value = { ...this.details.value, [id]: cached.detail };
    } catch {
      // Sin caché, la pantalla espera el tópico.
    }
  }

  /** Revocado o desemparejado: se olvida todo (la caché también). */
  wipe(): void {
    this.home.value = null;
    this.details.value = {};
    this.activity.value = null;
    this.lastUpdated.value = null;
    this.#topicCounts.clear();
    void this.#cache?.clear().catch(() => {});
  }
}

export { prTopic };
