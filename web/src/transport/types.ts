import type { Bytes } from "../crypto/bytes";
import type { CommandFailure, Incompatibility } from "../protocol/appFrames";
import { INCOMPATIBLE_MESSAGE } from "../protocol/version";

// Tipos compartidos por el transporte, el emparejamiento y el almacenamiento.

/** Reloj inyectable (los tests usan uno manual). */
export interface Clock {
  /** Milisegundos desde 1970. */
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemClock: Clock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** Las tres claves privadas de largo plazo del teléfono (32 bytes cada una, W.3). */
export interface DeviceKeys {
  /** Ed25519: se autentica ante el relay. */
  relay: Bytes;
  /** X25519: estática de Noise. */
  noise: Bytes;
  /** X25519: destinatario HPKE de pushes y buzón. */
  push: Bytes;
}

/** Lo que el teléfono sabe de su Mac (PairedMac de RemoteKeys.swift). */
export interface PairedMac {
  accountId: string;
  deviceId: string;
  /** `host` o `host:puerto`. */
  relayHost: string;
  macName: string;
  /** `macStatic.pub` (X25519). */
  macStatic: Bytes;
  /** `macSealKey.pub` (X25519). */
  macSeal: Bytes;
}

/** La passkey del teléfono como la conoce la Mac (W.4.5). La crea la UI con WebAuthn antes del handshake. */
export interface PresenceCredential {
  credentialId: Bytes;
  /** SPKI DER de la P-256. */
  publicKey: Bytes;
  /** El host del relay (sin puerto). */
  rpId: string;
}

/** Lo que devuelve `navigator.credentials.get` para el desafío (W.5). */
export interface PresenceAssertion {
  credentialId: Uint8Array;
  authenticatorData: Uint8Array;
  clientDataJSON: Uint8Array;
  /** ECDSA P-256 en DER. */
  signature: Uint8Array;
}

/** Firma el desafío con la passkey (Face ID). Lo implementa la UI con WebAuthn. */
export type Authorize = (challenge: Uint8Array) => Promise<PresenceAssertion>;

export type RemoteErrorCode =
  | "notPaired" | "macOffline" | "relayUnreachable" | "revoked" | "relayRejected" | "replaced" | "incompatible"
  | "pairingCancelled" | "pairingExpired" | "handshakeFailed" | "sessionClosed" | "timeout" | "presenceRequired"
  | "connecting";

const MESSAGES: Record<Exclude<RemoteErrorCode, "incompatible">, string> = {
  notPaired: "This iPhone isn’t paired with a Mac.",
  macOffline: "Your Mac is offline.",
  relayUnreachable: "Can’t reach the relay server.",
  revoked: "This iPhone was removed from your Mac.",
  relayRejected: "The relay server didn’t accept this iPhone. Check iPhone access in PRBar on your Mac.",
  replaced: "PRBar is open in another window. Close it there to use it here.",
  pairingCancelled: "Pairing was cancelled on your Mac.",
  pairingExpired: "This code expired or was already used. Show a new one on your Mac.",
  handshakeFailed: "Couldn’t open a secure session with your Mac.",
  sessionClosed: "The connection with your Mac was reset. Try again.",
  timeout: "Your Mac didn’t answer in time. Refresh to see whether it ran.",
  presenceRequired: "Face ID is required for this on iPhone.",
  connecting: "Still connecting to your Mac. Try again in a moment.",
};

/** Un error del lado del teléfono, con el texto que muestra la UI (RemoteError de RemoteClient.swift). */
export class RemoteError extends Error {
  constructor(readonly code: RemoteErrorCode, readonly incompatibility?: Incompatibility, readonly since?: number) {
    super(code === "incompatible" ? INCOMPATIBLE_MESSAGE[incompatibility ?? "updateMac"] : MESSAGES[code]);
  }
}

/** La Mac contestó con un error (`CommandFailure`): el texto va tal cual a la UI. */
export class CommandError extends Error {
  constructor(readonly failure: CommandFailure) {
    super(failure.message);
  }

  get code(): string {
    return this.failure.code;
  }
}
