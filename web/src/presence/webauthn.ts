import { concat, randomBytes, type Bytes } from "../crypto/bytes";
import type { Authorize, PresenceAssertion, PresenceCredential } from "../transport/types";

// Face ID con passkey (spec W.4.6 y W.5). La passkey se crea en el toque de "Pair" (gesto del usuario), antes del
// handshake; la Mac guarda su clave pública (SPKI) y, para cada comando gated, el teléfono firma el desafío con
// `navigator.credentials.get` (Face ID en el iPhone). La Mac verifica todo: esto solo arma los pedidos.

/** El usuario cerró el aviso de Face ID (o venció): no se manda nada y la pantalla queda como estaba. */
export class PresenceCancelled extends Error {
  constructor() {
    super("Face ID was cancelled.");
  }
}

/** No se pudo pedir Face ID (sin passkey, navegador sin WebAuthn, otro error): el texto va a la pantalla. */
export class PresenceUnavailable extends Error {}

export const NO_PASSKEY_MESSAGE = "Face ID isn't set up on this device. Pair it again.";

export interface CredentialsAPI {
  create(options: CredentialCreationOptions): Promise<Credential | null>;
  get(options: CredentialRequestOptions): Promise<Credential | null>;
}

function credentialsAPI(): CredentialsAPI | null {
  const api = (globalThis.navigator as Navigator | undefined)?.credentials;
  return api && typeof api.create === "function" && typeof globalThis.PublicKeyCredential !== "undefined" ? api : null;
}

// --- CBOR mínimo (solo lo que trae `attestationObject` y una clave COSE) ---

type CBOR = number | bigint | string | Uint8Array | CBOR[] | Map<CBOR, CBOR> | boolean | null | undefined;

export function decodeCBOR(data: Uint8Array): { value: CBOR; length: number } {
  let offset = 0;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const need = (n: number) => {
    if (offset + n > data.length) throw new Error("cbor: truncated");
  };
  const readLength = (info: number): number => {
    if (info < 24) return info;
    if (info === 24) {
      need(1);
      return data[offset++]!;
    }
    if (info === 25) {
      need(2);
      const v = view.getUint16(offset);
      offset += 2;
      return v;
    }
    if (info === 26) {
      need(4);
      const v = view.getUint32(offset);
      offset += 4;
      return v;
    }
    if (info === 27) {
      need(8);
      const v = view.getBigUint64(offset);
      offset += 8;
      if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("cbor: integer too large");
      return Number(v);
    }
    throw new Error("cbor: indefinite lengths are not supported");
  };
  const item = (depth: number): CBOR => {
    if (depth > 16) throw new Error("cbor: too deep");
    need(1);
    const initial = data[offset++]!;
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0:
        return readLength(info);
      case 1:
        return -1 - readLength(info);
      case 2: {
        const n = readLength(info);
        need(n);
        const out = data.slice(offset, offset + n);
        offset += n;
        return out;
      }
      case 3: {
        const n = readLength(info);
        need(n);
        const out = new TextDecoder("utf-8", { fatal: true }).decode(data.subarray(offset, offset + n));
        offset += n;
        return out;
      }
      case 4: {
        const n = readLength(info);
        const out: CBOR[] = [];
        for (let i = 0; i < n; i++) out.push(item(depth + 1));
        return out;
      }
      case 5: {
        const n = readLength(info);
        const out = new Map<CBOR, CBOR>();
        for (let i = 0; i < n; i++) {
          const key = item(depth + 1);
          out.set(key, item(depth + 1));
        }
        return out;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        if (info === 23) return undefined;
        throw new Error("cbor: unsupported simple value");
      default:
        throw new Error("cbor: unsupported type");
    }
  };
  const value = item(0);
  return { value, length: offset };
}

/** Prefijo DER de una SubjectPublicKeyInfo P-256 sin comprimir (id-ecPublicKey + prime256v1). */
const P256_SPKI_PREFIX = Uint8Array.from([
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce,
  0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]);

/** Una clave COSE EC2 P-256 ES256 (`{1: 2, 3: -7, -1: 1, -2: x, -3: y}`) → SPKI DER. */
export function coseToSPKI(cose: Uint8Array): Bytes {
  const { value } = decodeCBOR(cose);
  if (!(value instanceof Map)) throw new Error("cose: not a map");
  const x = value.get(-2);
  const y = value.get(-3);
  if (value.get(1) !== 2 || value.get(3) !== -7 || value.get(-1) !== 1) throw new Error("cose: not an ES256 P-256 key");
  if (!(x instanceof Uint8Array) || !(y instanceof Uint8Array) || x.length !== 32 || y.length !== 32) {
    throw new Error("cose: bad coordinates");
  }
  return concat(P256_SPKI_PREFIX, Uint8Array.of(0x04), x, y);
}

/** De `authenticatorData` (con `attestedCredentialData`): el id de la credencial y su clave COSE. */
export function parseAttestedCredential(authData: Uint8Array): { credentialId: Uint8Array; cose: Uint8Array } {
  // rpIdHash(32) ‖ flags(1) ‖ signCount(4) ‖ aaguid(16) ‖ credIdLen(2) ‖ credId ‖ clave COSE ‖ [extensiones]
  if (authData.length < 55 || (authData[32]! & 0x40) === 0) throw new Error("authData: no attested credential");
  const length = (authData[53]! << 8) | authData[54]!;
  const start = 55;
  if (authData.length < start + length) throw new Error("authData: truncated");
  const credentialId = authData.slice(start, start + length);
  const rest = authData.subarray(start + length);
  const { length: coseLength } = decodeCBOR(rest);
  return { credentialId, cose: rest.slice(0, coseLength) };
}

/** `authenticatorData` del `attestationObject` (CBOR `{fmt, attStmt, authData}`). */
export function authDataFromAttestation(attestationObject: Uint8Array): Uint8Array {
  const { value } = decodeCBOR(attestationObject);
  const authData = value instanceof Map ? value.get("authData") : undefined;
  if (!(authData instanceof Uint8Array)) throw new Error("attestation: no authData");
  return authData;
}

interface AttestationResponseLike {
  attestationObject: ArrayBuffer;
  getPublicKey?: () => ArrayBuffer | null;
  getAuthenticatorData?: () => ArrayBuffer;
}

/** La SPKI de una credencial nueva: `getPublicKey()` si el navegador lo tiene; si no, desde la clave COSE. */
export function publicKeyFromAttestation(response: AttestationResponseLike): Bytes {
  const direct = typeof response.getPublicKey === "function" ? response.getPublicKey() : null;
  if (direct) return new Uint8Array(direct) as Bytes;
  const authData = typeof response.getAuthenticatorData === "function"
    ? new Uint8Array(response.getAuthenticatorData())
    : authDataFromAttestation(new Uint8Array(response.attestationObject));
  return coseToSPKI(parseAttestedCredential(authData).cose);
}

export interface CreatePasskeyOptions {
  /** El host del relay, que es el de la página (`location.hostname`). */
  rpId: string;
  /** Lo que muestra el llavero ("PRBar · iPhone"). */
  userName: string;
  credentials?: CredentialsAPI | null;
}

/** Crea la passkey de este dispositivo (W.4.6). Tira `PresenceCancelled` si el usuario cancela y
 *  `PresenceUnavailable` si el navegador no puede. */
export async function createPasskey(options: CreatePasskeyOptions): Promise<PresenceCredential> {
  const api = options.credentials === undefined ? credentialsAPI() : options.credentials;
  if (!api) throw new PresenceUnavailable("This browser can't create a passkey.");
  let credential: Credential | null;
  try {
    credential = await api.create({
      publicKey: {
        rp: { id: options.rpId, name: "PRBar" },
        user: { id: randomBytes(16) as BufferSource, name: options.userName, displayName: options.userName },
        challenge: randomBytes(32) as BufferSource,
        pubKeyCredParams: [{ type: "public-key", alg: -7 }],
        authenticatorSelection: { authenticatorAttachment: "platform", residentKey: "required",
                                  requireResidentKey: true, userVerification: "required" },
        attestation: "none",
        timeout: 60_000,
      },
    });
  } catch (error) {
    throw mapError(error);
  }
  const pk = credential as (Credential & { rawId: ArrayBuffer; response: AttestationResponseLike }) | null;
  if (!pk?.rawId || !pk.response) throw new PresenceUnavailable("The passkey couldn't be created.");
  let publicKey: Bytes;
  try {
    publicKey = publicKeyFromAttestation(pk.response);
  } catch {
    throw new PresenceUnavailable("The passkey couldn't be read.");
  }
  return { credentialId: new Uint8Array(pk.rawId) as Bytes, publicKey, rpId: options.rpId };
}

function mapError(error: unknown): Error {
  const name = (error as { name?: unknown } | null)?.name;
  // NotAllowedError: el usuario cerró el aviso (o venció el tiempo). AbortError: se canceló el pedido.
  if (name === "NotAllowedError" || name === "AbortError") return new PresenceCancelled();
  const message = (error as { message?: unknown } | null)?.message;
  return new PresenceUnavailable(typeof message === "string" && message ? message : "Face ID isn't available right now.");
}

/** Firma un desafío con la passkey (W.5): `allowCredentials` con la credencial guardada, UV obligatorio. */
export function passkeyAuthorizer(credential: PresenceCredential, credentials?: CredentialsAPI | null): Authorize {
  return async (challenge: Uint8Array): Promise<PresenceAssertion> => {
    const api = credentials === undefined ? credentialsAPI() : credentials;
    if (!api) throw new PresenceUnavailable("This browser can't use passkeys.");
    let result: Credential | null;
    try {
      result = await api.get({
        publicKey: {
          rpId: credential.rpId,
          challenge: challenge as BufferSource,
          allowCredentials: [{ type: "public-key", id: credential.credentialId as BufferSource }],
          userVerification: "required",
          timeout: 60_000,
        },
      });
    } catch (error) {
      throw mapError(error);
    }
    const pk = result as (Credential & {
      rawId: ArrayBuffer;
      response: { authenticatorData: ArrayBuffer; clientDataJSON: ArrayBuffer; signature: ArrayBuffer };
    }) | null;
    if (!pk?.response) throw new PresenceCancelled();
    return {
      credentialId: new Uint8Array(pk.rawId),
      authenticatorData: new Uint8Array(pk.response.authenticatorData),
      clientDataJSON: new Uint8Array(pk.response.clientDataJSON),
      signature: new Uint8Array(pk.response.signature),
    };
  };
}
