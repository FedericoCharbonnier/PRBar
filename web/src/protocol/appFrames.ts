import { b64Decode, b64Encode, b64urlDecode, b64urlEncode } from "../crypto/b64";
import { concat, type Bytes } from "../crypto/bytes";
import type { PresenceProofJSON } from "../crypto/presence";
import {
  DecodeError, expectBool, expectInt, expectObject, expectString, isObject, isoDate, optionalString, parseISODate,
  parseJSONBytes, swiftJSONBytes, type JSONValue,
} from "./json";

// Marcos de aplicación (spec P.6), copia de RemoteFrame.swift: viajan dentro de la sesión de Noise partidos en trozos
// (`chunkFrame`/`FrameAssembler`, Framing.swift). JSON con claves ordenadas y fechas ISO 8601; un objeto plano con
// `t` = el tipo. Los `Data` de Swift (como `cmd`) van en base64 estándar con relleno.

/** Versión del framing y de estos marcos. */
export const REMOTE_PROTOCOL = 1;

export type Incompatibility = "updateMac" | "updateIPhone";

export interface RemoteHello {
  remoteProtocol: number;
  commandProtocol: number;
  appVersion: string;
  deviceName?: string;
  macName?: string;
  /** Solo en el `hello` de la Mac: por qué el teléfono no puede seguir. */
  incompatible?: Incompatibility;
}

export interface RemoteRequest {
  id: number;
  /** Milisegundos; viaja como ISO 8601 sin fracción. */
  sentAt: number;
  /** Los bytes JSON del `AppCommand` tal cual se firmaron (P.8). */
  cmd: Bytes;
  presence?: PresenceProofJSON;
  /** Hasta cuándo espera el teléfono (L3), en milisegundos. */
  deadline?: number;
}

export interface CommandFailure {
  code: "invalidUsage" | "notFound" | "invalidState" | "confirmationRequired" | "failed" | "cancelled"
    | "protocolMismatch" | "unauthorized" | (string & {});
  message: string;
}

/** `progress` (una línea de progreso) o `text` (un pedazo del chat en streaming). */
export type CommandEvent = { progress: { message: string } } | { text: { delta: string } };

export interface CommandResponse {
  id: number;
  /** Ausente en los eventos. */
  ok?: boolean;
  result?: JSONValue;
  error?: CommandFailure;
  event?: CommandEvent;
}

export interface RemoteStateUpdate {
  topic: string;
  rev: number;
  data: JSONValue;
}

export type RemoteFrame =
  | ({ t: "hello" } & RemoteHello)
  | ({ t: "req" } & RemoteRequest)
  | ({ t: "res" } & CommandResponse)
  | { t: "sub"; topics: string[] }
  | ({ t: "state" } & RemoteStateUpdate)
  | { t: "chatDelta"; pr: string; text: string }
  | { t: "unpair" }
  | { t: "presencePolicy"; requirePresence: boolean; gated: string[] }
  | { t: "bye"; reason?: string }
  | { t: "unknown"; type: string };

function compact<T extends object>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)) as T;
}

export function encodeFrame(frame: RemoteFrame): Bytes {
  switch (frame.t) {
    case "req":
      return swiftJSONBytes({
        t: "req", id: frame.id, sentAt: isoDate(frame.sentAt), cmd: b64Encode(frame.cmd), presence: frame.presence,
        deadline: frame.deadline === undefined ? undefined : isoDate(frame.deadline),
      });
    case "unknown":
      return swiftJSONBytes({ t: frame.type });
    default:
      return swiftJSONBytes(frame);
  }
}

function decodeHello(c: Record<string, unknown>): RemoteHello {
  const incompatible = optionalString(c.incompatible, "incompatible");
  return compact({
    remoteProtocol: expectInt(c.remoteProtocol, "remoteProtocol"),
    commandProtocol: expectInt(c.commandProtocol, "commandProtocol"),
    appVersion: expectString(c.appVersion, "appVersion"),
    deviceName: optionalString(c.deviceName, "deviceName"),
    macName: optionalString(c.macName, "macName"),
    // Un motivo que esta versión no conoce cuenta como "actualizá la Mac" (el teléfono no puede seguir igual).
    incompatible: incompatible === undefined ? undefined
      : incompatible === "updateIPhone" ? "updateIPhone" : "updateMac",
  }) as RemoteHello;
}

function decodeDate(value: unknown, what: string): number {
  const millis = parseISODate(value);
  if (millis === null) throw new DecodeError(`${what} is not a date`);
  return millis;
}

function decodePresence(value: unknown): PresenceProofJSON {
  const c = expectObject(value, "presence");
  if (c.v !== 2) throw new DecodeError("presence.v is not 2");
  const field = (key: string) => {
    const text = expectString(c[key], key);
    b64urlDecode(text);
    return text;
  };
  return {
    v: 2, ts: expectInt(c.ts, "ts"), credentialId: field("credentialId"),
    authenticatorData: field("authenticatorData"), clientDataJSON: field("clientDataJSON"), signature: field("signature"),
  };
}

export function decodeFailure(value: unknown): CommandFailure {
  const c = expectObject(value, "error");
  return { code: expectString(c.code, "code"), message: expectString(c.message, "message") };
}

export function decodeEvent(value: unknown): CommandEvent {
  const c = expectObject(value, "event");
  if (isObject(c.progress)) return { progress: { message: expectString(c.progress.message, "message") } };
  if (isObject(c.text)) return { text: { delta: expectString(c.text.delta, "delta") } };
  throw new DecodeError("unknown event");
}

export function decodeResponse(c: Record<string, unknown>): CommandResponse {
  return compact({
    id: expectInt(c.id, "id"),
    ok: c.ok === undefined || c.ok === null ? undefined : expectBool(c.ok, "ok"),
    result: c.result === undefined ? undefined : (c.result as JSONValue),
    error: c.error === undefined || c.error === null ? undefined : decodeFailure(c.error),
    event: c.event === undefined || c.event === null ? undefined : decodeEvent(c.event),
  }) as CommandResponse;
}

function stringArray(value: unknown, what: string): string[] {
  if (!Array.isArray(value)) throw new DecodeError(`${what} is not an array`);
  return value.map((item, i) => expectString(item, `${what}[${i}]`));
}

export function decodeFrame(data: Uint8Array): RemoteFrame {
  let parsed: unknown;
  try {
    parsed = parseJSONBytes(data);
  } catch {
    throw new DecodeError("frame is not JSON");
  }
  const c = expectObject(parsed, "frame");
  const t = expectString(c.t, "t");
  switch (t) {
    case "hello":
      return { t, ...decodeHello(c) };
    case "req": {
      let cmd: Bytes;
      try {
        cmd = b64Decode(expectString(c.cmd, "cmd"));
      } catch {
        throw new DecodeError("cmd is not base64");
      }
      return compact({
        t, id: expectInt(c.id, "id"), sentAt: decodeDate(c.sentAt, "sentAt"), cmd,
        presence: c.presence === undefined || c.presence === null ? undefined : decodePresence(c.presence),
        deadline: c.deadline === undefined || c.deadline === null ? undefined : decodeDate(c.deadline, "deadline"),
      }) as RemoteFrame;
    }
    case "res":
      return { t, ...decodeResponse(c) };
    case "sub":
      return { t, topics: stringArray(c.topics, "topics") };
    case "state":
      if (!("data" in c)) throw new DecodeError("state without data");
      return { t, topic: expectString(c.topic, "topic"), rev: expectInt(c.rev, "rev"), data: c.data as JSONValue };
    case "chatDelta":
      return { t, pr: expectString(c.pr, "pr"), text: expectString(c.text, "text") };
    case "unpair":
      return { t };
    case "presencePolicy":
      return { t, requirePresence: expectBool(c.requirePresence, "requirePresence"), gated: stringArray(c.gated, "gated") };
    case "bye":
      return compact({ t, reason: optionalString(c.reason, "reason") }) as RemoteFrame;
    default:
      return { t: "unknown", type: t };
  }
}

// --- Trozos (Framing.swift) ---

export const MAX_FRAME_SIZE = 16 << 20;
export const CHUNK_BLOCK = 256;
export const MAX_CHUNK_PLAINTEXT = 65_280;
export const MAX_CHUNK_DATA = MAX_CHUNK_PLAINTEXT - 3;
const MORE = 0b01;
const COMPRESSED = 0b10;

export class FramingError extends Error {
  constructor(readonly code: "tooLarge" | "malformed") {
    super(`framing: ${code}`);
  }
}

/** Parte un marco en trozos: `flags(u8) ‖ len(u16 BE) ‖ datos ‖ ceros` hasta un múltiplo de 256. Nunca comprime
 *  (P.15 M2). */
export function chunkFrame(data: Uint8Array): Bytes[] {
  if (data.length > MAX_FRAME_SIZE) throw new FramingError("tooLarge");
  const chunks: Bytes[] = [];
  let offset = 0;
  do {
    const end = Math.min(offset + MAX_CHUNK_DATA, data.length);
    const length = end - offset;
    const size = Math.ceil((3 + length) / CHUNK_BLOCK) * CHUNK_BLOCK;
    const chunk = new Uint8Array(size);
    chunk[0] = end < data.length ? MORE : 0;
    chunk[1] = length >> 8;
    chunk[2] = length & 0xff;
    chunk.set(data.subarray(offset, end), 3);
    chunks.push(chunk);
    offset = end;
  } while (offset < data.length);
  return chunks;
}

/** Rearma un marco. Falla apenas lo acumulado pasa el tope. Un trozo comprimido (bit 1) se rechaza: la Mac no
 *  comprime desde P.15 M2 y el navegador solo descomprime de forma asíncrona. */
export class FrameAssembler {
  #parts: Bytes[] = [];
  #size = 0;

  /** El marco cuando llega el último trozo; `null` mientras falten. */
  add(chunk: Uint8Array): Bytes | null {
    if (chunk.length < CHUNK_BLOCK || chunk.length > MAX_CHUNK_PLAINTEXT || chunk.length % CHUNK_BLOCK !== 0) {
      throw new FramingError("malformed");
    }
    const flags = chunk[0]!;
    if ((flags & ~MORE) !== 0 || (flags & COMPRESSED) !== 0) throw new FramingError("malformed");
    const length = (chunk[1]! << 8) | chunk[2]!;
    if (length > chunk.length - 3) throw new FramingError("malformed");
    for (let i = 3 + length; i < chunk.length; i++) if (chunk[i] !== 0) throw new FramingError("malformed");
    if (this.#size + length > MAX_FRAME_SIZE) throw new FramingError("tooLarge");
    this.#parts.push(chunk.slice(3, 3 + length));
    this.#size += length;
    if (flags & MORE) return null;
    const frame = concat(...this.#parts);
    this.#parts = [];
    this.#size = 0;
    return frame;
  }
}

// --- Emparejamiento (PairingMessage de SecureChannel.swift: la síntesis de Swift de un enum con valor asociado
// sin etiqueta da `{"join":{"_0":{…}}}`) ---

export interface PresenceCredentialJSON {
  credentialId: Bytes;
  /** SPKI DER de una P-256 (ES256). */
  publicKey: Bytes;
  rpId: string;
}

export interface PairingJoin {
  deviceName: string;
  model: string;
  /** Ed25519 pública (32). */
  relayKey: Bytes;
  /** X25519 pública de push (32). */
  push: Bytes;
  presence?: PresenceCredentialJSON;
}

export interface PairingResult {
  deviceId: string;
  macName: string;
  macSeal: Bytes;
  relayHost: string;
}

export type PairingMessage =
  | { kind: "join"; join: PairingJoin }
  | { kind: "confirm" }
  | { kind: "result"; result: PairingResult }
  | { kind: "ack" }
  | { kind: "cancelled" };

export function encodePairingMessage(message: PairingMessage): Bytes {
  switch (message.kind) {
    case "join": {
      const { join } = message;
      return swiftJSONBytes({
        join: {
          _0: {
            deviceName: join.deviceName, model: join.model, relayKey: b64Encode(join.relayKey), push: b64Encode(join.push),
            presence: join.presence && {
              credentialId: b64urlEncode(join.presence.credentialId), publicKey: b64urlEncode(join.presence.publicKey),
              rpId: join.presence.rpId,
            },
          },
        },
      });
    }
    case "result": {
      const { result } = message;
      return swiftJSONBytes({
        result: { _0: { deviceId: result.deviceId, macName: result.macName, macSeal: b64Encode(result.macSeal),
                        relayHost: result.relayHost } },
      });
    }
    default:
      return swiftJSONBytes({ [message.kind]: {} });
  }
}

export function decodePairingMessage(data: Uint8Array): PairingMessage {
  let parsed: unknown;
  try {
    parsed = parseJSONBytes(data);
  } catch {
    throw new DecodeError("pairing message is not JSON");
  }
  const c = expectObject(parsed, "pairing message");
  const keys = Object.keys(c);
  if (keys.length !== 1) throw new DecodeError("pairing message must have one case");
  const kind = keys[0]!;
  const std = (value: unknown, what: string): Bytes => {
    try {
      return b64Decode(expectString(value, what));
    } catch {
      throw new DecodeError(`${what} is not base64`);
    }
  };
  switch (kind) {
    case "confirm":
    case "ack":
    case "cancelled":
      expectObject(c[kind], kind);
      return { kind };
    case "result": {
      const r = expectObject(expectObject(c.result, "result")._0, "result._0");
      return {
        kind, result: { deviceId: expectString(r.deviceId, "deviceId"), macName: expectString(r.macName, "macName"),
                        macSeal: std(r.macSeal, "macSeal"), relayHost: expectString(r.relayHost, "relayHost") },
      };
    }
    case "join": {
      const j = expectObject(expectObject(c.join, "join")._0, "join._0");
      const join: PairingJoin = {
        deviceName: expectString(j.deviceName, "deviceName"), model: expectString(j.model, "model"),
        relayKey: std(j.relayKey, "relayKey"), push: std(j.push, "push"),
      };
      if (j.presence !== undefined && j.presence !== null) {
        const p = expectObject(j.presence, "presence");
        const url = (value: unknown, what: string) => {
          try {
            return b64urlDecode(expectString(value, what));
          } catch {
            throw new DecodeError(`${what} is not base64url`);
          }
        };
        join.presence = { credentialId: url(p.credentialId, "credentialId"), publicKey: url(p.publicKey, "publicKey"),
                          rpId: expectString(p.rpId, "rpId") };
      }
      return { kind, join };
    }
    default:
      throw new DecodeError(`unknown pairing message ${kind}`);
  }
}
