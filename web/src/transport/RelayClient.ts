import type { Bytes } from "../crypto/bytes";
import { pairingProof, signRelayAuth } from "../crypto/relayAuth";
import { isValidHost } from "../protocol/pairingQR";
import {
  decodeRelayMessage, encodeRelayMessage, RELAY_MAX_FRAME, RELAY_SUBPROTOCOL, RelayCloseCode, type RelayMessage,
} from "../protocol/relayFrames";
import { systemClock, type Clock } from "./types";

// La conexión con el relay (spec P.4): `wss://<host>/v1/ws`, subprotocolo `prbar-relay.v1`, desafío → auth → ready.
// `RelayLink` es una conexión (como WebSocketRelayLink.swift); `RelayClient` la mantiene viva: reconecta con backoff
// (1, 2, 4… 30 s con jitter), se va a los 30 s de pasar la página a segundo plano y vuelve al primer plano (R.3).
// Un WebSocket puede quedar muerto sin que nadie avise (el iPhone se durmió, cambió de Wi-Fi a datos): cada `ping`
// espera su `pong` y, si no llega a tiempo, la conexión se da por caída y se rehace. Al volver de un rato en segundo
// plano (o con `online`/`pageshow`) se comprueba enseguida con un `ping`.

/** Lo mínimo de `WebSocket` que se usa (los tests inyectan uno falso). */
export interface WebSocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: ((event: { code: number; reason: string }) => void) | null;
  onerror: ((event: unknown) => void) | null;
}

export type WebSocketFactory = (url: string, protocols: string[]) => WebSocketLike;

// Los manejadores de `WebSocket` reciben eventos del DOM; acá solo se lee `data`, `code` y `reason`.
export const browserWebSocket: WebSocketFactory = (url, protocols) =>
  new WebSocket(url, protocols) as unknown as WebSocketLike;

/** Con qué se presenta el cliente. */
export type RelayCredential =
  /** Un teléfono emparejado (`client = deviceId`): firma Ed25519 del desafío con `deviceRelayKey`. */
  | { kind: "signed"; account: string; client: string; key: Bytes }
  /** Un teléfono emparejándose: `proof` = HMAC(`pairAuthKey`, `nonce`). */
  | { kind: "pairing"; account: string; pairing: string; authKey: Bytes };

export interface RelayReady {
  mac: "online" | "offline";
  since: number;
}

/** El relay cerró la conexión (o no se pudo abrir). `code` = el código de cierre del WebSocket, si hubo. */
export class RelayClosedError extends Error {
  constructor(readonly code: number | null, readonly reason: string) {
    super(`relay closed${code === null ? "" : ` (${code})`}: ${reason}`);
  }
}

export interface RelayLinkOptions {
  /** `prbar.example.org` o `prbar.example.org:8443`. */
  host: string;
  credential: RelayCredential;
  webSocket?: WebSocketFactory;
  clock?: Clock;
  /** `ws://` y una IP literal: solo para el relay local de los tests. */
  insecure?: boolean;
  /** Tope para llegar a `ready` (desafío y auth). */
  connectTimeoutMs?: number;
}

const PING_INTERVAL_MS = 20_000;
/** Cuánto se espera el `pong` de un `ping` antes de dar la conexión por muerta. */
export const PONG_TIMEOUT_MS = 5_000;
/** El `reason` de una conexión que se dio por muerta porque no llegó el `pong`. */
const NO_PONG = "The relay stopped answering";

function authFor(credential: RelayCredential, host: string, nonce: Bytes): RelayMessage {
  if (credential.kind === "signed") {
    return { t: "auth", acct: credential.account, client: credential.client,
             sig: signRelayAuth(credential.key, host, credential.account, credential.client, nonce) };
  }
  return { t: "auth", acct: credential.account, client: "pair", pairing: credential.pairing,
           proof: pairingProof(credential.authKey, nonce) };
}

/** Una conexión autenticada con el relay. Después de `connect()` entrega cada marco a `onMessage` (salvo `pong`) y
 *  avisa una vez por `onClose` si la cierra el otro lado o la red; `close()` propio no avisa. */
export class RelayLink {
  onMessage: (message: RelayMessage) => void = () => {};
  onClose: (error: RelayClosedError) => void = () => {};

  readonly #options: RelayLinkOptions;
  readonly #clock: Clock;
  #socket: WebSocketLike | null = null;
  #open = false;
  #closed = false;
  #ping: unknown = null;
  #pongTimer: unknown = null;
  #lastHeard = 0;

  /** Cada marco que llega después de `ready` (también los `pong`): la conexión anda. */
  onHeard: () => void = () => {};

  constructor(options: RelayLinkOptions) {
    this.#options = options;
    this.#clock = options.clock ?? systemClock;
  }

  connect(): Promise<RelayReady> {
    const { host, credential, insecure = false } = this.#options;
    if (!isValidHost(host, insecure)) return Promise.reject(new RelayClosedError(null, "Invalid relay host"));
    const url = `${insecure ? "ws" : "wss"}://${host}/v1/ws`;
    return new Promise<RelayReady>((resolve, reject) => {
      let settled = false;
      const fail = (error: RelayClosedError) => {
        if (settled) return;
        settled = true;
        this.#clock.clearTimeout(timer);
        this.#teardown();
        reject(error);
      };
      const timer = this.#clock.setTimeout(() => {
        this.#socket?.close(1000, "timeout");
        fail(new RelayClosedError(null, "The relay didn't answer"));
      }, this.#options.connectTimeoutMs ?? 15_000);
      let socket: WebSocketLike;
      try {
        socket = (this.#options.webSocket ?? browserWebSocket)(url, [RELAY_SUBPROTOCOL]);
      } catch (error) {
        fail(new RelayClosedError(null, String(error)));
        return;
      }
      this.#socket = socket;
      let stage: "challenge" | "ready" = "challenge";
      socket.onmessage = (event) => {
        const message = this.#decode(event.data);
        if (!message) return;
        if (settled) {
          this.#heard();
          if (message.t !== "pong") this.onMessage(message);
          return;
        }
        if (stage === "challenge" && message.t === "challenge") {
          stage = "ready";
          // Se firma el host público sin puerto (signRelayAuth lo quita).
          this.#write(authFor(credential, host, message.nonce));
        } else if (stage === "ready" && message.t === "ready") {
          settled = true;
          this.#clock.clearTimeout(timer);
          this.#open = true;
          this.#lastHeard = this.#clock.now();
          this.#schedulePing();
          resolve({ mac: message.mac === "online" ? "online" : "offline", since: message.since });
        } else {
          socket.close(1002, "unexpected frame");
          fail(new RelayClosedError(null, `Expected ${stage}`));
        }
      };
      socket.onclose = (event) => {
        const error = new RelayClosedError(event.code === 1005 || event.code === 1006 ? null : event.code,
                                           event.reason || "Connection closed");
        if (!settled) fail(error);
        else this.#ended(error);
      };
      socket.onerror = () => {
        // Siempre le sigue `onclose`, que trae el código.
      };
    });
  }

  get isOpen(): boolean {
    return this.#open;
  }

  /** Cuándo llegó el último marco (ms). */
  get lastHeard(): number {
    return this.#lastHeard;
  }

  /** Comprueba ya que la conexión anda: manda un `ping` (si no hay uno esperando su `pong`). Sin `pong` a tiempo, la
   *  conexión se cierra y avisa por `onClose`. */
  probe(): void {
    if (!this.#open || this.#pongTimer !== null) return;
    try {
      this.#write({ t: "ping" });
    } catch {
      return;
    }
    this.#pongTimer = this.#clock.setTimeout(() => {
      this.#pongTimer = null;
      if (!this.#open) return;
      this.#socket?.close(1000, "no pong");
      this.#ended(new RelayClosedError(null, NO_PONG));
    }, PONG_TIMEOUT_MS);
  }

  /** Encola un marco. Tira `RelayClosedError` si la conexión no está abierta o el marco pasa el tope. */
  send(message: RelayMessage): void {
    if (!this.#open || !this.#socket) throw new RelayClosedError(null, "Not connected");
    this.#write(message);
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    const socket = this.#socket;
    this.#teardown();
    socket?.close(1000, "closed");
  }

  #write(message: RelayMessage): void {
    const text = encodeRelayMessage(message);
    if (text.length > RELAY_MAX_FRAME) throw new RelayClosedError(RelayCloseCode.tooLarge, "Frame too large");
    this.#socket!.send(text);
  }

  #decode(data: unknown): RelayMessage | null {
    try {
      if (typeof data !== "string") throw new Error("Unexpected binary frame");
      if (data.length > RELAY_MAX_FRAME) throw new Error("Frame too large");
      return decodeRelayMessage(data);
    } catch (error) {
      // Un marco que no se entiende corta la conexión (como el lector de WebSocketRelayLink).
      const closed = new RelayClosedError(null, error instanceof Error ? error.message : "Bad frame");
      this.#socket?.close(1002, "bad frame");
      if (this.#open) this.#ended(closed);
      return null;
    }
  }

  #schedulePing(): void {
    this.#ping = this.#clock.setTimeout(() => {
      if (!this.#open) return;
      this.probe();
      this.#schedulePing();
    }, PING_INTERVAL_MS);
  }

  #heard(): void {
    this.#lastHeard = this.#clock.now();
    if (this.#pongTimer !== null) this.#clock.clearTimeout(this.#pongTimer);
    this.#pongTimer = null;
    this.onHeard();
  }

  #ended(error: RelayClosedError): void {
    const wasOpen = this.#open && !this.#closed;
    this.#teardown();
    if (wasOpen) {
      this.#closed = true;
      this.onClose(error);
    }
  }

  #teardown(): void {
    this.#open = false;
    if (this.#ping !== null) this.#clock.clearTimeout(this.#ping);
    this.#ping = null;
    if (this.#pongTimer !== null) this.#clock.clearTimeout(this.#pongTimer);
    this.#pongTimer = null;
    if (this.#socket) {
      this.#socket.onmessage = null;
      this.#socket.onclose = null;
      this.#socket.onerror = null;
    }
  }
}

// --- Conexión que se mantiene ---

export type RelayState =
  /** Sin conexión porque no se pidió (o la página está en segundo plano). */
  | { kind: "idle" }
  | { kind: "connecting" }
  | { kind: "ready"; mac: "online" | "offline"; since: number }
  /** Caído: se reintenta solo en `retryAt` (ms). */
  | { kind: "unreachable"; retryAt: number | null; code: number | null }
  /** 4401/4403: el relay no acepta este dispositivo. No prueba una revocación (M3): no se borra nada y se reintenta
   *  con la próxima operación (`retryNow`) o al volver al primer plano. */
  | { kind: "rejected"; code: number }
  /** 4409: otra ventana se conectó con el mismo dispositivo. No se reintenta solo (se pisarían entre las dos). */
  | { kind: "replaced" };

/** Si la página está visible (`document.visibilityState`). Inyectable para los tests. */
export interface VisibilitySource {
  visible(): boolean;
  onChange(listener: (visible: boolean) => void): () => void;
  /** La red volvió (`online`) o la página salió de la caché de ida y vuelta (`pageshow` con `persisted`): la conexión
   *  que había puede estar muerta. */
  onWake?(listener: () => void): () => void;
}

export const documentVisibility: VisibilitySource | null = typeof document === "undefined" ? null : {
  visible: () => document.visibilityState === "visible",
  onChange: (listener) => {
    const handler = () => listener(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", handler);
    return () => document.removeEventListener("visibilitychange", handler);
  },
  onWake: (listener) => {
    const online = () => listener();
    const pageshow = (event: PageTransitionEvent) => {
      if (event.persisted) listener();
    };
    addEventListener("online", online);
    addEventListener("pageshow", pageshow);
    return () => {
      removeEventListener("online", online);
      removeEventListener("pageshow", pageshow);
    };
  },
};

export interface RelayClientOptions extends RelayLinkOptions {
  /** `null`: sin ciclo de vida de la página (tests, service worker). Por defecto el `document`. */
  visibility?: VisibilitySource | null;
  /** [0, 1) para el jitter. */
  random?: () => number;
  /** Cuánto sigue conectado después de pasar a segundo plano. */
  hiddenGraceMs?: number;
}

const BACKOFF_MAX_S = 30;
/** Más que esto en segundo plano: al volver, la conexión se comprueba con un `ping` antes de confiar en ella. */
export const RESUME_CHECK_MS = 15_000;
/** Sin oír nada del relay en este tiempo (los `ping` van cada 20 s), la conexión está en duda. */
const QUIET_MS = PING_INTERVAL_MS + PONG_TIMEOUT_MS;
/** Un corte poco después de volver (o de comprobar la conexión) se reintenta enseguida, sin pasar por "unreachable". */
const WAKE_WINDOW_MS = 10_000;

export class RelayClient {
  readonly #options: RelayClientOptions;
  readonly #clock: Clock;
  readonly #random: () => number;
  #state: RelayState = { kind: "idle" };
  #link: RelayLink | null = null;
  #wanted = false;
  #attempt = 0;
  #retryTimer: unknown = null;
  #hiddenTimer: unknown = null;
  #hiddenAt: number | null = null;
  /** Se pidió comprobar la conexión (al volver) y todavía no se oyó nada. */
  #suspect = false;
  #wokeAt: number | null = null;
  #unwatch: (() => void) | null = null;
  #unwake: (() => void) | null = null;
  #heardWaiters: (() => void)[] = [];
  readonly #stateListeners = new Set<(state: RelayState) => void>();
  readonly #messageListeners = new Set<(message: RelayMessage) => void>();

  constructor(options: RelayClientOptions) {
    this.#options = options;
    this.#clock = options.clock ?? systemClock;
    this.#random = options.random ?? Math.random;
  }

  get state(): RelayState {
    return this.#state;
  }

  subscribe(listener: (state: RelayState) => void): () => void {
    this.#stateListeners.add(listener);
    return () => this.#stateListeners.delete(listener);
  }

  onMessage(listener: (message: RelayMessage) => void): () => void {
    this.#messageListeners.add(listener);
    return () => this.#messageListeners.delete(listener);
  }

  /** Quiere estar conectado (mientras la página esté visible). */
  start(): void {
    if (this.#wanted) return;
    this.#wanted = true;
    const visibility = this.#visibility;
    if (visibility && !this.#unwatch) this.#unwatch = visibility.onChange((visible) => this.#visibilityChanged(visible));
    if (visibility?.onWake && !this.#unwake) this.#unwake = visibility.onWake(() => this.#wake());
    this.#connect();
  }

  stop(): void {
    this.#wanted = false;
    this.#unwatch?.();
    this.#unwatch = null;
    this.#unwake?.();
    this.#unwake = null;
    this.#clearTimers();
    if (this.#hiddenTimer !== null) this.#clock.clearTimeout(this.#hiddenTimer);
    this.#hiddenTimer = null;
    this.#dropLink();
    this.#setState({ kind: "idle" });
  }

  /** Reintenta ya (Try Again, o la próxima operación después de un `rejected`/`replaced`). */
  retryNow(): void {
    if (!this.#wanted) return this.start();
    if (this.#state.kind === "ready" || this.#state.kind === "connecting") return;
    this.#attempt = 0;
    this.#connect();
  }

  /** La conexión está `ready` pero en duda: se pidió comprobarla y no contestó todavía, o hace rato que no se oye
   *  nada (los timers no corren con la página congelada). Algo que no puede esperar (Face ID) no debería usarla. */
  get stale(): boolean {
    const link = this.#link;
    if (this.#state.kind !== "ready" || !link) return false;
    return this.#suspect || this.#clock.now() - link.lastHeard > QUIET_MS;
  }

  /** Comprueba ya que la conexión anda (un `ping`; sin `pong` en 5 s se rehace). Caída: reintenta ya. */
  probe(): void {
    if (!this.#wanted) return;
    if (this.#state.kind === "ready") {
      if (this.stale) this.#suspect = true;
      this.#link?.probe();
    } else if (this.#state.kind === "unreachable" || this.#state.kind === "idle") {
      this.#attempt = 0;
      this.#connect();
    }
  }

  /** Se resuelve cuando se oye al relay o la conexión cambia de estado (o a los 6 s): para esperar un `probe`. */
  settled(): Promise<void> {
    return new Promise((resolve) => {
      const done = () => {
        this.#clock.clearTimeout(timer);
        this.#heardWaiters = this.#heardWaiters.filter((w) => w !== done);
        resolve();
      };
      const timer = this.#clock.setTimeout(done, PONG_TIMEOUT_MS + 1000);
      this.#heardWaiters.push(done);
    });
  }

  /** Manda un marco; tira `RelayClosedError` si no hay conexión lista. */
  send(message: RelayMessage): void {
    if (!this.#link || this.#state.kind !== "ready") throw new RelayClosedError(null, "Not connected");
    this.#link.send(message);
  }

  get #visibility(): VisibilitySource | null {
    return this.#options.visibility === undefined ? documentVisibility : this.#options.visibility;
  }

  #connect(): void {
    this.#clearTimers();
    this.#dropLink();
    this.#setState({ kind: "connecting" });
    const link = new RelayLink(this.#options);
    this.#link = link;
    this.#suspect = false;
    link.onHeard = () => {
      if (this.#link !== link) return;
      this.#suspect = false;
      this.#releaseWaiters();
    };
    link.onMessage = (message) => {
      if (this.#link !== link) return;
      // La presencia de la Mac también cambia el estado.
      if (message.t === "presence" && message.mac !== undefined && this.#state.kind === "ready") {
        this.#setState({ kind: "ready", mac: message.mac === "online" ? "online" : "offline",
                         since: message.since ?? this.#state.since });
      }
      for (const listener of [...this.#messageListeners]) listener(message);
    };
    link.onClose = (error) => {
      if (this.#link !== link) return;
      this.#link = null;
      this.#closed(error);
    };
    link.connect().then(
      (ready) => {
        if (this.#link !== link) return;
        this.#attempt = 0;
        this.#setState({ kind: "ready", mac: ready.mac, since: ready.since });
      },
      (error: unknown) => {
        if (this.#link !== link) return;
        this.#link = null;
        this.#closed(error instanceof RelayClosedError ? error : new RelayClosedError(null, String(error)));
      },
    );
  }

  #closed(error: RelayClosedError): void {
    if (!this.#wanted) return this.#setState({ kind: "idle" });
    if (error.code === RelayCloseCode.unauthorized || error.code === RelayCloseCode.deviceRemoved) {
      return this.#setState({ kind: "rejected", code: error.code });
    }
    if (error.code === RelayCloseCode.replaced) return this.#setState({ kind: "replaced" });
    // Se cortó con la página en segundo plano (iOS mata el WebSocket al congelarla): sin reintentos ni "unreachable";
    // al volver al primer plano se conecta de nuevo.
    if (this.#visibility && !this.#visibility.visible()) {
      if (this.#hiddenTimer !== null) this.#clock.clearTimeout(this.#hiddenTimer);
      this.#hiddenTimer = null;
      return this.#setState({ kind: "idle" });
    }
    // Una conexión que murió en silencio (sin `pong`) o se cortó justo al volver: otra enseguida, sin mostrar
    // "no se puede conectar" por algo normal como desbloquear el teléfono.
    const woke = this.#wokeAt !== null && this.#clock.now() - this.#wokeAt < WAKE_WINDOW_MS;
    if (this.#attempt === 0 && (woke || error.reason === NO_PONG)) {
      this.#wokeAt = null;
      this.#attempt = 1;
      return this.#connect();
    }
    // 1, 2, 4, 8, 16 y 30 s, ±20 %.
    const base = Math.min(BACKOFF_MAX_S, 2 ** this.#attempt) * 1000;
    this.#attempt = Math.min(this.#attempt + 1, 10);
    const delay = Math.round(base * (0.8 + 0.4 * this.#random()));
    const retryAt = this.#clock.now() + delay;
    this.#retryTimer = this.#clock.setTimeout(() => {
      this.#retryTimer = null;
      this.#connect();
    }, delay);
    this.#setState({ kind: "unreachable", retryAt, code: error.code });
  }

  #visibilityChanged(visible: boolean): void {
    if (!this.#wanted) return;
    if (!visible) {
      this.#hiddenAt ??= this.#clock.now();
      if (this.#hiddenTimer === null) {
        this.#hiddenTimer = this.#clock.setTimeout(() => {
          this.#hiddenTimer = null;
          this.#clearTimers();
          this.#dropLink();
          this.#setState({ kind: "idle" });
        }, this.#options.hiddenGraceMs ?? 30_000);
      }
      return;
    }
    if (this.#hiddenTimer !== null) this.#clock.clearTimeout(this.#hiddenTimer);
    this.#hiddenTimer = null;
    const hiddenFor = this.#hiddenAt === null ? 0 : this.#clock.now() - this.#hiddenAt;
    this.#hiddenAt = null;
    if (this.#state.kind !== "ready" && this.#state.kind !== "connecting") {
      this.#attempt = 0;
      this.#wokeAt = this.#clock.now();
      this.#connect();
    } else if (hiddenFor > RESUME_CHECK_MS) {
      // iOS congela la página en segundo plano: el timer de arriba pudo no correr y el WebSocket pudo morir sin
      // avisar. Se comprueba antes de confiar en él.
      this.#wake();
    }
  }

  /** Volvió la red o la página: la conexión `ready` se comprueba; una caída se reintenta ya. */
  #wake(): void {
    if (!this.#wanted) return;
    this.#wokeAt = this.#clock.now();
    if (this.#state.kind === "ready") {
      this.#suspect = true;
      this.#link?.probe();
    } else if (this.#state.kind === "unreachable") {
      this.#attempt = 0;
      this.#connect();
    }
  }

  #releaseWaiters(): void {
    const waiters = this.#heardWaiters;
    this.#heardWaiters = [];
    for (const waiter of waiters) waiter();
  }

  /** Solo el reintento: el timer de segundo plano sigue corriendo aunque se reconecte mientras tanto. */
  #clearTimers(): void {
    if (this.#retryTimer !== null) this.#clock.clearTimeout(this.#retryTimer);
    this.#retryTimer = null;
  }

  #dropLink(): void {
    const link = this.#link;
    this.#link = null;
    link?.close();
  }

  #setState(state: RelayState): void {
    this.#state = state;
    this.#releaseWaiters();
    for (const listener of [...this.#stateListeners]) listener(state);
  }
}
