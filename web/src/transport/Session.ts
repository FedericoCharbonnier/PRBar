import { randomBytes, toHex, type Bytes } from "../crypto/bytes";
import { NoiseHandshake, sessionPrologue, type NoiseTransport } from "../crypto/noise";
import { presenceChallenge, presenceProofJSON } from "../crypto/presence";
import {
  chunkFrame, decodeFrame, encodeFrame, FrameAssembler, REMOTE_PROTOCOL, type CommandEvent, type CommandResponse,
  type RemoteFrame, type RemoteHello, type RemoteStateUpdate,
} from "../protocol/appFrames";
import { encodeCommand, type AppCommand } from "../protocol/commands";
import type { RelayMessage } from "../protocol/relayFrames";
import { COMMAND_PROTOCOL, helloIncompatibility } from "../protocol/version";
import { RemoteError, systemClock, type Authorize, type Clock } from "./types";

// Una sesión cifrada con la Mac (spec P.5 y P.6, la parte de sesión de RemoteClient.swift): handshake Noise KK
// iniciado por el teléfono, `hello` en los dos sentidos, pedidos con id creciente y tiempo límite, eventos, `sub`,
// `state` sin volver atrás dentro de la sesión, `chatDelta`, `presencePolicy` y `bye`. Un trozo que no autentica, un
// marco roto o un `bye` cierran la sesión: quien la usa abre otra. Un pedido vencido falla solo; la sesión queda en duda
// y se prueba con un `status`: si ese tampoco contesta, se cierra.

export interface PresencePolicy {
  requirePresence: boolean;
  gated: string[];
}

export interface SessionOptions {
  account: string;
  device: string;
  /** `deviceStatic` privada (X25519). */
  deviceStatic: Bytes;
  /** `macStatic.pub`. */
  macStatic: Bytes;
  appVersion: string;
  deviceName: string;
  commandProtocol?: number;
  /** Manda un marco al relay (puede tirar si no hay conexión: la sesión se cierra). */
  send: (message: RelayMessage) => void;
  clock?: Clock;
  handshakeTimeoutMs?: number;
  /** Lo que espera cada pedido por la respuesta (o por un evento, que lo reinicia), y el `deadline` del `req`. */
  requestTimeoutMs?: number;
  /** Lo que espera el `status` que prueba la sesión después de un pedido vencido. */
  probeTimeoutMs?: number;
  /** Solo para los vectores de prueba. */
  sid?: string;
  fixedEphemeral?: Bytes;
}

export interface SessionHandlers {
  onState?: (update: RemoteStateUpdate) => void;
  onChatDelta?: (pr: string, text: string) => void;
  onPresencePolicy?: (policy: PresencePolicy) => void;
  /** Una vez, cuando la sesión deja de servir (no se llama por `close()` propio salvo que se pida). */
  onClose?: (error: RemoteError) => void;
}

export interface RequestOptions {
  /** Firma el desafío de presencia (comandos gated, W.5). Sin esto el `req` va sin prueba. */
  authorize?: Authorize;
  onEvent?: (event: CommandEvent) => void;
  /**
   * Cuánto puede pasar sin respuesta ni eventos (cada evento lo reinicia). Por defecto `requestTimeoutMs`. Para lo que
   * transmite un rato largo (el chat: Claude puede pensar minutos sin escribir). El `deadline` del `req` no cambia:
   * la Mac igual lo rechaza si le llega tarde.
   */
  timeoutMs?: number;
}

export interface SentRequest {
  id: number;
  /** La respuesta final (con `ok` y `result` o `error`). Falla con `RemoteError` si la sesión muere o vence. */
  response: Promise<CommandResponse>;
}

/** Rotación (spec P.5): handshake nuevo a las 24 h o a los 2²⁰ mensajes en cualquier dirección. */
const MAX_AGE_MS = 24 * 3_600_000;
const MAX_MESSAGES = 1n << 20n;

type Phase = "idle" | "handshake" | "hello" | "open" | "closed";

interface Pending {
  resolve: (response: CommandResponse) => void;
  reject: (error: RemoteError) => void;
  onEvent: ((event: CommandEvent) => void) | undefined;
  timer: unknown;
  /** Vuelve a armar el tiempo límite (llegó un evento). */
  rearm: () => void;
}

export class Session {
  readonly sid: string;
  readonly #options: SessionOptions;
  readonly #clock: Clock;
  #handlers: SessionHandlers;
  #phase: Phase = "idle";
  #handshake: NoiseHandshake | null = null;
  #transport: NoiseTransport | null = null;
  #assembler = new FrameAssembler();
  #hash: Bytes | null = null;
  #startedAt = 0;
  #macHello: RemoteHello | null = null;
  #policy: PresencePolicy = { requirePresence: true, gated: [] };
  #nextId = 0;
  #pending = new Map<number, Pending>();
  #revs = new Map<string, number>();
  /** Hay un `status` en vuelo probando si la sesión sigue viva. */
  #probing = false;
  #waiter: { resolve: (value: Bytes | RemoteHello) => void; reject: (error: RemoteError) => void; timer: unknown } | null =
    null;

  constructor(options: SessionOptions, handlers: SessionHandlers = {}) {
    this.#options = options;
    this.#clock = options.clock ?? systemClock;
    this.#handlers = handlers;
    // 8 bytes al azar del iniciador, en hex.
    this.sid = options.sid ?? toHex(randomBytes(8));
  }

  get isOpen(): boolean {
    return this.#phase === "open";
  }

  get isClosed(): boolean {
    return this.#phase === "closed";
  }

  /** El hash del handshake: identifica la sesión en la prueba de presencia. */
  get handshakeHash(): Bytes | null {
    return this.#hash;
  }

  get macHello(): RemoteHello | null {
    return this.#macHello;
  }

  get presencePolicy(): PresencePolicy {
    return this.#policy;
  }

  /** Handshake KK + `hello`. Tira `RemoteError` (`handshakeFailed`, `incompatible`, …) y deja la sesión cerrada. */
  async open(): Promise<RemoteHello> {
    if (this.#phase !== "idle") throw new RemoteError("sessionClosed");
    const o = this.#options;
    try {
      this.#handshake = new NoiseHandshake({
        pattern: "kk", initiator: true, prologue: sessionPrologue(o.account, o.device), localStatic: o.deviceStatic,
        remoteStatic: o.macStatic, fixedEphemeral: o.fixedEphemeral ?? null,
      });
      this.#phase = "handshake";
      // El primer mensaje no lleva payload (es repetible: nunca comandos).
      const first = this.#handshake.writeMessage();
      const reply = this.#wait<Bytes>("handshakeFailed");
      this.#relay(first);
      await reply;
      this.#phase = "hello";
      const hello = this.#wait<RemoteHello>("handshakeFailed");
      this.#sendFrame({ t: "hello", remoteProtocol: REMOTE_PROTOCOL, commandProtocol: o.commandProtocol ?? COMMAND_PROTOCOL,
                        appVersion: o.appVersion, deviceName: o.deviceName });
      const macHello = await hello;
      const incompatible = helloIncompatibility(macHello);
      if (incompatible) throw new RemoteError("incompatible", incompatible);
      this.#phase = "open";
      return macHello;
    } catch (error) {
      const remote = error instanceof RemoteError ? error : new RemoteError("handshakeFailed");
      this.#close(remote, false);
      throw remote;
    }
  }

  /** Un `recv` de la Mac con este `sid`. */
  receive(b: Bytes): void {
    try {
      if (this.#phase === "handshake") {
        this.#handshake!.readMessage(b);
        this.#transport = this.#handshake!.split();
        this.#hash = this.#handshake!.handshakeHash;
        this.#handshake = null;
        this.#startedAt = this.#clock.now();
        this.#settle(b);
        return;
      }
      if (this.#phase !== "hello" && this.#phase !== "open") return;
      const chunk = this.#transport!.receive.decrypt(b);
      const data = this.#assembler.add(chunk);
      if (data) this.#handleFrame(decodeFrame(data));
    } catch {
      // Un trozo que no autentica o un marco roto: la sesión no sirve más (P.5).
      this.#close(new RemoteError(this.#phase === "handshake" ? "handshakeFailed" : "sessionClosed"), true);
    }
  }

  /** Manda un comando. Con `authorize`, firma el desafío atado a esta sesión, al id, a los bytes y a la hora. */
  async request(command: AppCommand, options: RequestOptions = {}): Promise<SentRequest> {
    if (this.#phase !== "open") throw new RemoteError("sessionClosed");
    const id = ++this.#nextId;
    const cmd = encodeCommand(command);
    let presence;
    if (options.authorize) {
      const ts = this.#clock.now();
      const assertion = await options.authorize(presenceChallenge(this.#hash!, id, cmd, ts));
      // Face ID pudo tardar: si la sesión cambió, la prueba ya no sirve.
      if (this.#phase !== "open") throw new RemoteError("sessionClosed");
      presence = presenceProofJSON({ tsMillis: ts, ...assertion });
    }
    const base = this.#options.requestTimeoutMs ?? 60_000;
    const timeout = options.timeoutMs ?? base;
    const response = new Promise<CommandResponse>((resolve, reject) => {
      const expire = () => {
        if (!this.#pending.delete(id)) return;
        reject(new RemoteError("timeout"));
        // La sesión queda en duda (la Mac pudo perderla sin avisar, M3), pero un pedido lento no la tira: se prueba.
        this.#probe();
      };
      const entry: Pending = {
        resolve, reject, onEvent: options.onEvent, timer: this.#clock.setTimeout(expire, timeout),
        rearm: () => {
          this.#clock.clearTimeout(entry.timer);
          entry.timer = this.#clock.setTimeout(expire, timeout);
        },
      };
      this.#pending.set(id, entry);
    });
    // Que un rechazo sin nadie escuchando todavía no se reporte como no manejado.
    response.catch(() => {});
    const sentAt = this.#clock.now();
    this.#sendFrame({ t: "req", id, sentAt, cmd, ...(presence ? { presence } : {}), deadline: sentAt + base });
    return { id, response };
  }

  /** Reemplaza el conjunto de tópicos. */
  subscribe(topics: string[]): void {
    if (this.#phase === "open") this.#sendFrame({ t: "sub", topics });
  }

  /** "Unpair this iPhone": la Mac lo da de baja como un Revoke. */
  sendUnpair(): void {
    if (this.#phase === "open") this.#sendFrame({ t: "unpair" }, false);
  }

  /** Cierra la sesión (sin avisar a `onClose`). Lo que estaba en vuelo falla con `error`. */
  close(error: RemoteError = new RemoteError("sessionClosed")): void {
    this.#close(error, false);
  }

  #handleFrame(frame: RemoteFrame): void {
    switch (frame.t) {
      case "hello": {
        if (this.#phase !== "hello") return;
        const { t: _t, ...hello } = frame;
        this.#macHello = hello;
        this.#settle(hello);
        return;
      }
      case "res": {
        const pending = this.#pending.get(frame.id);
        if (!pending) return;
        const { t: _t, ...response } = frame;
        if (response.event) {
          // La Mac está trabajando en esto: el tiempo límite cuenta desde el último evento.
          pending.rearm();
          pending.onEvent?.(response.event);
          return;
        }
        this.#pending.delete(frame.id);
        this.#clock.clearTimeout(pending.timer);
        pending.resolve(response);
        return;
      }
      case "state": {
        // El estado no vuelve atrás dentro de la sesión (L1: otra sesión puede numerar desde 1).
        if (frame.rev <= (this.#revs.get(frame.topic) ?? 0)) return;
        this.#revs.set(frame.topic, frame.rev);
        this.#handlers.onState?.({ topic: frame.topic, rev: frame.rev, data: frame.data });
        return;
      }
      case "presencePolicy":
        this.#policy = { requirePresence: frame.requirePresence, gated: frame.gated };
        this.#handlers.onPresencePolicy?.(this.#policy);
        return;
      case "chatDelta":
        this.#handlers.onChatDelta?.(frame.pr, frame.text);
        return;
      case "bye":
        // Solo un `bye(revoked)` dentro de la sesión prueba una revocación (M3). `rotate`, `desync`…: otra sesión.
        this.#close(new RemoteError(frame.reason === "revoked" ? "revoked" : "sessionClosed"), true);
        return;
      default:
        return;
    }
  }

  /** Después de un pedido vencido: un `status` corto. Si no contesta, la sesión no sirve (M3) y se cierra. */
  #probe(): void {
    if (this.#probing || this.#phase !== "open") return;
    this.#probing = true;
    const timeoutMs = this.#options.probeTimeoutMs ?? 15_000;
    this.request({ status: {} }, { timeoutMs }).then(
      (sent) => sent.response.then(
        () => (this.#probing = false),
        () => {
          this.#probing = false;
          this.#close(new RemoteError("sessionClosed"), true);
        },
      ),
      () => (this.#probing = false),
    );
  }

  #sendFrame(frame: RemoteFrame, checkRotation = true): void {
    if (!this.#transport) return;
    try {
      for (const chunk of chunkFrame(encodeFrame(frame))) this.#relay(this.#transport.send.encrypt(chunk));
    } catch {
      this.#close(new RemoteError("relayUnreachable"), true);
      return;
    }
    if (checkRotation && this.#needsRotation()) {
      this.#sendFrame({ t: "bye", reason: "rotate" }, false);
      this.#close(new RemoteError("sessionClosed"), true);
    }
  }

  #needsRotation(): boolean {
    const t = this.#transport!;
    return this.#clock.now() - this.#startedAt >= MAX_AGE_MS || t.send.n >= MAX_MESSAGES || t.receive.n >= MAX_MESSAGES;
  }

  #relay(b: Bytes): void {
    this.#options.send({ t: "send", to: "mac", sid: this.sid, b });
  }

  #wait<T extends Bytes | RemoteHello>(onTimeout: "handshakeFailed"): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = this.#clock.setTimeout(() => {
        this.#waiter = null;
        reject(new RemoteError(onTimeout));
      }, this.#options.handshakeTimeoutMs ?? 15_000);
      this.#waiter = { resolve: resolve as (value: Bytes | RemoteHello) => void, reject, timer };
    });
  }

  #settle(value: Bytes | RemoteHello): void {
    const waiter = this.#waiter;
    this.#waiter = null;
    if (!waiter) return;
    this.#clock.clearTimeout(waiter.timer);
    waiter.resolve(value);
  }

  #close(error: RemoteError, notify: boolean): void {
    if (this.#phase === "closed") return;
    const wasOpen = this.#phase === "open";
    this.#phase = "closed";
    this.#transport = null;
    this.#handshake = null;
    const waiter = this.#waiter;
    this.#waiter = null;
    if (waiter) {
      this.#clock.clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    for (const pending of this.#pending.values()) {
      this.#clock.clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
    // Durante `open()` el error vuelve por la promesa; `onClose` es para una sesión que ya andaba.
    if (notify && wasOpen) this.#handlers.onClose?.(error);
  }
}
