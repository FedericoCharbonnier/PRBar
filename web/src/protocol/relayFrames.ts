import { b64urlDecode, b64urlEncode } from "../crypto/b64";
import type { Bytes } from "../crypto/bytes";
import { DecodeError, expectInt, expectObject, expectString, swiftJSON } from "./json";

// Marcos del relay (spec P.4 y W.6), copia de RelayMessages.swift: JSON de texto por el WebSocket, claves cortas y
// ordenadas, el cifrado en base64url sin relleno (`b`). Los campos binarios son `Uint8Array`.

export const RelayCloseCode = {
  unauthorized: 4401,
  deviceRemoved: 4403,
  authTimeout: 4408,
  replaced: 4409,
  tooLarge: 4413,
  rateLimited: 4429,
} as const;

/** Tope de un marco del relay (128 KiB). */
export const RELAY_MAX_FRAME = 128 * 1024;
export const RELAY_SUBPROTOCOL = "prbar-relay.v1";

export interface RelayMailboxItem {
  slot: string;
  b: Bytes;
  at: number;
}

export interface RelayDeviceEntry {
  id: string;
  lastSeen: number;
}

export type RelayMessage =
  | { t: "challenge"; nonce: Bytes; time: number }
  /** `client`: `mac`, un `deviceId` o `pair` (con `pairing` y `proof` en vez de `sig`). */
  | { t: "auth"; acct: string; client: string; sig?: Bytes; pairing?: string; proof?: Bytes }
  | { t: "ready"; mac: string; since: number }
  | { t: "send"; to: string; sid: string; b: Bytes }
  | { t: "recv"; from: string; sid: string; b: Bytes }
  | { t: "undeliverable"; to: string; sid: string }
  /** A los teléfonos: `mac` + `since`. A la Mac: `device` + `state`. */
  | { t: "presence"; mac?: string; since?: number; device?: string; state?: string }
  | { t: "push"; id: string; to: string; collapse: string; thread: string; b: Bytes }
  | { t: "pushResult"; id: string; status: number; reason?: string }
  | { t: "mbox.put"; to: string; slot: string; b: Bytes }
  | { t: "mbox.get" }
  | { t: "mbox"; items: RelayMailboxItem[] }
  /** La suscripción de Web Push del teléfono: `p256dh` (65 bytes) y `auth` (16). */
  | { t: "webpush"; endpoint: string; p256dh: Bytes; auth: Bytes }
  | { t: "pair.open"; pairing: string; authKey: Bytes; expires: number }
  | { t: "pair.close"; pairing: string }
  | { t: "device.add"; device: string; relayKey: Bytes }
  | { t: "device.remove"; device: string }
  /** Pedido de la Mac (sin `items`) y respuesta del relay (con `items`). */
  | { t: "devices"; items?: RelayDeviceEntry[] }
  | { t: "error"; reason: string }
  | { t: "ping" }
  | { t: "pong" }
  /** Un tipo que esta versión no conoce: se ignora. */
  | { t: "unknown"; type: string };

/** El texto del marco de WebSocket. */
export function encodeRelayMessage(message: RelayMessage): string {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(message)) {
    if (value === undefined) continue;
    if (value instanceof Uint8Array) out[key] = b64urlEncode(value);
    else if (key === "items" && message.t === "mbox") {
      out.items = message.items.map((item) => ({ slot: item.slot, b: b64urlEncode(item.b), at: item.at }));
    } else out[key] = value;
  }
  if (message.t === "unknown") return swiftJSON({ t: message.type });
  return swiftJSON(out);
}

export function decodeRelayMessage(text: string): RelayMessage {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new DecodeError("relay frame is not JSON");
  }
  const c = expectObject(parsed, "relay frame");
  const t = expectString(c.t, "t");
  const str = (key: string) => expectString(c[key], key);
  const int = (key: string) => expectInt(c[key], key);
  const bytes = (key: string): Bytes => {
    try {
      return b64urlDecode(str(key));
    } catch (error) {
      if (error instanceof DecodeError) throw error;
      throw new DecodeError(`${key} is not base64url`);
    }
  };
  const optString = (key: string) => (c[key] === undefined || c[key] === null ? undefined : str(key));
  const optInt = (key: string) => (c[key] === undefined || c[key] === null ? undefined : int(key));
  const optBytes = (key: string) => (c[key] === undefined || c[key] === null ? undefined : bytes(key));
  // Los opcionales ausentes no aparecen como `undefined` (exactOptionalPropertyTypes y comparaciones en los tests).
  const compact = <T extends object>(value: T): T =>
    Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)) as T;
  switch (t) {
    case "challenge":
      return { t, nonce: bytes("nonce"), time: int("time") };
    case "auth":
      return compact({ t, acct: str("acct"), client: str("client"), sig: optBytes("sig"), pairing: optString("pairing"),
                       proof: optBytes("proof") }) as RelayMessage;
    case "ready":
      return { t, mac: str("mac"), since: int("since") };
    case "send":
      return { t, to: str("to"), sid: str("sid"), b: bytes("b") };
    case "recv":
      return { t, from: str("from"), sid: str("sid"), b: bytes("b") };
    case "undeliverable":
      return { t, to: str("to"), sid: str("sid") };
    case "presence":
      return compact({ t, mac: optString("mac"), since: optInt("since"), device: optString("device"),
                       state: optString("state") }) as RelayMessage;
    case "push":
      return { t, id: str("id"), to: str("to"), collapse: str("collapse"), thread: str("thread"), b: bytes("b") };
    case "pushResult":
      return compact({ t, id: str("id"), status: int("status"), reason: optString("reason") }) as RelayMessage;
    case "mbox.put":
      return { t, to: str("to"), slot: str("slot"), b: bytes("b") };
    case "mbox.get":
      return { t };
    case "mbox": {
      if (!Array.isArray(c.items)) throw new DecodeError("items is not an array");
      const items = c.items.map((raw, i): RelayMailboxItem => {
        const item = expectObject(raw, `items[${i}]`);
        let b: Bytes;
        try {
          b = b64urlDecode(expectString(item.b, "b"));
        } catch {
          throw new DecodeError("b is not base64url");
        }
        return { slot: expectString(item.slot, "slot"), b, at: expectInt(item.at, "at") };
      });
      return { t, items };
    }
    case "webpush":
      return { t, endpoint: str("endpoint"), p256dh: bytes("p256dh"), auth: bytes("auth") };
    case "pair.open":
      return { t, pairing: str("pairing"), authKey: bytes("authKey"), expires: int("expires") };
    case "pair.close":
      return { t, pairing: str("pairing") };
    case "device.add":
      return { t, device: str("device"), relayKey: bytes("relayKey") };
    case "device.remove":
      return { t, device: str("device") };
    case "devices": {
      if (c.items === undefined || c.items === null) return { t };
      if (!Array.isArray(c.items)) throw new DecodeError("items is not an array");
      return {
        t,
        items: c.items.map((raw, i) => {
          const item = expectObject(raw, `items[${i}]`);
          return { id: expectString(item.id, "id"), lastSeen: expectInt(item.lastSeen, "lastSeen") };
        }),
      };
    }
    case "error":
      return { t, reason: str("reason") };
    case "ping":
    case "pong":
      return { t };
    default:
      return { t: "unknown", type: t };
  }
}

