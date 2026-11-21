import type { Bytes } from "../../../src/crypto/bytes";
import { constantTimeEqual, randomBytes } from "../../../src/crypto/bytes";
import { pairingProof, verifyRelayAuth } from "../../../src/crypto/relayAuth";
import {
  decodeRelayMessage, encodeRelayMessage, type RelayMailboxItem, type RelayMessage,
} from "../../../src/protocol/relayFrames";
import type { WebSocketFactory, WebSocketLike } from "../../../src/transport/RelayClient";
import type { Clock } from "../../../src/transport/types";

// Lo que comparten los tests del transporte: un reloj manual y un relay en memoria que habla el protocolo de P.4.

export class ManualClock implements Clock {
  #now: number;
  #timers: { at: number; seq: number; fn: () => void }[] = [];
  #seq = 0;

  constructor(start = Date.UTC(2026, 10, 20, 12, 38)) {
    this.#now = start;
  }

  now(): number {
    return this.#now;
  }

  setTimeout(fn: () => void, ms: number): unknown {
    const timer = { at: this.#now + Math.max(0, ms), seq: this.#seq++, fn };
    this.#timers.push(timer);
    return timer;
  }

  clearTimeout(handle: unknown): void {
    this.#timers = this.#timers.filter((t) => t !== handle);
  }

  get pending(): number {
    return this.#timers.length;
  }

  /** Avanza el reloj corriendo cada timer vencido (y lo que eso desencadene). */
  async advance(ms: number): Promise<void> {
    const end = this.#now + ms;
    for (;;) {
      await flush();
      const due = this.#timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at || a.seq - b.seq)[0];
      if (!due) break;
      this.#timers = this.#timers.filter((t) => t !== due);
      this.#now = Math.max(this.#now, due.at);
      due.fn();
    }
    this.#now = end;
    await flush();
  }
}

/** Deja correr las promesas pendientes. */
export async function flush(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((resolve) => setImmediate(resolve));
}

type Role = { kind: "device"; account: string; device: string } | { kind: "pair"; account: string; pairing: string };

export class FakeSocket implements WebSocketLike {
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: ((event: { code: number; reason: string }) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;
  role: Role | null = null;
  closed = false;
  readonly sent: RelayMessage[] = [];

  constructor(readonly relay: FakeRelay, readonly url: string, readonly protocols: string[]) {}

  send(data: string): void {
    if (this.closed) throw new Error("socket closed");
    const message = decodeRelayMessage(data);
    this.sent.push(message);
    queueMicrotask(() => this.relay.receive(this, message));
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.relay.disconnected(this);
  }

  /** Del relay al cliente. */
  deliver(message: RelayMessage | string): void {
    if (this.closed) return;
    const data = typeof message === "string" ? message : encodeRelayMessage(message);
    queueMicrotask(() => this.onmessage?.({ data }));
  }

  /** El relay (o la red) corta con `code`. */
  drop(code: number, reason = ""): void {
    if (this.closed) return;
    this.closed = true;
    this.relay.disconnected(this);
    queueMicrotask(() => this.onclose?.({ code, reason }));
  }
}

export interface RelayDevice {
  account: string;
  device: string;
  relayKey: Bytes;
}

/** Un relay en memoria (spec P.4): desafío, auth (firma Ed25519 o `proof` de la ranura), ruteo hacia la Mac
 *  (`mac` es una función del test), buzón y Web Push. */
export class FakeRelay {
  host = "prbar.example.org";
  macOnline = true;
  macSince = 1_795_178_000;
  readonly sockets: FakeSocket[] = [];
  readonly devices: RelayDevice[] = [];
  readonly pairings = new Map<string, { account: string; authKey: Bytes }>();
  mailbox: RelayMailboxItem[] = [];
  readonly webpush: RelayMessage[] = [];
  /** Lo que manda el teléfono a la Mac. */
  mac: (from: FakeSocket, message: Extract<RelayMessage, { t: "send" }>) => void = () => {};
  nonce: Bytes = randomBytes(32);
  /** `false`: no contesta el desafío (para probar timeouts). */
  answers = true;

  readonly factory: WebSocketFactory = (url, protocols) => {
    const socket = new FakeSocket(this, url, protocols);
    this.sockets.push(socket);
    if (this.answers) socket.deliver({ t: "challenge", nonce: this.nonce, time: 1_795_178_280 });
    return socket;
  };

  get open(): FakeSocket[] {
    return this.sockets.filter((s) => !s.closed && s.role !== null);
  }

  get last(): FakeSocket {
    return this.sockets.at(-1)!;
  }

  receive(socket: FakeSocket, message: RelayMessage): void {
    if (socket.closed) return;
    if (!socket.role) {
      if (message.t !== "auth") return socket.drop(4401, "expected auth");
      const role = this.#authorize(message);
      if (!role) return socket.drop(4401, "unauthorized");
      // El mismo cliente conectado de nuevo reemplaza al anterior (4409).
      for (const other of this.open) {
        if (JSON.stringify(other.role) === JSON.stringify(role)) other.drop(4409, "replaced");
      }
      socket.role = role;
      socket.deliver({ t: "ready", mac: this.macOnline ? "online" : "offline", since: this.macSince });
      return;
    }
    switch (message.t) {
      case "ping":
        return socket.deliver({ t: "pong" });
      case "send":
        if (message.to !== "mac") return socket.deliver({ t: "error", reason: "forbidden" });
        if (!this.macOnline) return socket.deliver({ t: "undeliverable", to: "mac", sid: message.sid });
        return this.mac(socket, message);
      case "mbox.get":
        return socket.deliver({ t: "mbox", items: this.mailbox });
      case "webpush":
        this.webpush.push(message);
        return;
      default:
        return;
    }
  }

  disconnected(_socket: FakeSocket): void {}

  /** De la Mac a un teléfono (o a la ranura de emparejamiento). */
  fromMac(to: FakeSocket, sid: string, b: Bytes): void {
    to.deliver({ t: "recv", from: "mac", sid, b });
  }

  /** La Mac se conecta o se va: `presence` a los teléfonos conectados. */
  setMac(online: boolean): void {
    this.macOnline = online;
    for (const socket of this.open) {
      if (socket.role?.kind === "device") socket.deliver({ t: "presence", mac: online ? "online" : "offline", since: 1 });
    }
  }

  #authorize(message: Extract<RelayMessage, { t: "auth" }>): Role | null {
    if (message.client === "pair") {
      const slot = message.pairing === undefined ? undefined : this.pairings.get(message.pairing);
      if (!slot || !message.proof || slot.account !== message.acct) return null;
      return constantTimeEqual(pairingProof(slot.authKey, this.nonce), message.proof)
        ? { kind: "pair", account: message.acct, pairing: message.pairing! } : null;
    }
    const device = this.devices.find((d) => d.account === message.acct && d.device === message.client);
    if (!device || !message.sig) return null;
    if (!verifyRelayAuth(message.sig, device.relayKey, this.host, message.acct, message.client, this.nonce)) return null;
    return { kind: "device", account: message.acct, device: message.client };
  }
}

/** Visibilidad de la página manejada por el test. */
export class FakeVisibility {
  #visible = true;
  #listeners = new Set<(visible: boolean) => void>();

  visible(): boolean {
    return this.#visible;
  }

  onChange(listener: (visible: boolean) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  set(visible: boolean): void {
    this.#visible = visible;
    for (const listener of this.#listeners) listener(visible);
  }
}
