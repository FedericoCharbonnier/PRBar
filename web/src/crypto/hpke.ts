import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { expand, extract, hkdf } from "@noble/hashes/hkdf.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { concat, readU32BE, toHex, u32BE, utf8, type Bytes } from "./bytes";
import { generateX25519, x25519DH, x25519PublicKey } from "./curves";

// HPKE (RFC 9180) modo auth con DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 y ChaCha20Poly1305: el sobre de los pushes y
// del buzón (spec P.9 y Q.1, Sealed.swift). Remitente `macSealKey`, destinatario `devicePushKey`. El teléfono solo
// necesita abrir; `seal` está para los tests y los vectores.

export class HPKEError extends Error {
  constructor(message: string) {
    super(`hpke: ${message}`);
  }
}

const MODE_AUTH = 0x02;
const KEM_ID = 0x0020;
const KDF_ID = 0x0001;
const AEAD_ID = 0x0003;
const N_SECRET = 32;
const N_KEY = 32;
const N_NONCE = 12;
const N_TAG = 16;
const N_ENC = 32;
const EMPTY = new Uint8Array(0);

const i2osp2 = (n: number) => Uint8Array.of((n >> 8) & 0xff, n & 0xff);
const SUITE_KEM = concat(utf8("KEM"), i2osp2(KEM_ID));
const SUITE_HPKE = concat(utf8("HPKE"), i2osp2(KEM_ID), i2osp2(KDF_ID), i2osp2(AEAD_ID));
const VERSION = utf8("HPKE-v1");

function labeledExtract(suite: Uint8Array, salt: Uint8Array, label: string, ikm: Uint8Array): Bytes {
  return extract(sha256, concat(VERSION, suite, utf8(label), ikm), salt) as Bytes;
}

function labeledExpand(suite: Uint8Array, prk: Uint8Array, label: string, info: Uint8Array, length: number): Bytes {
  return expand(sha256, prk, concat(i2osp2(length), VERSION, suite, utf8(label), info), length) as Bytes;
}

function dh(privateKey: Uint8Array, publicKey: Uint8Array): Bytes {
  try {
    return x25519DH(privateKey, publicKey);
  } catch {
    throw new HPKEError("invalid key");
  }
}

/** DeriveKeyPair de DHKEM(X25519) (RFC 9180 §7.1.3). */
export function deriveKeyPair(ikm: Uint8Array): { privateKey: Bytes; publicKey: Bytes } {
  const prk = labeledExtract(SUITE_KEM, EMPTY, "dkp_prk", ikm);
  const privateKey = labeledExpand(SUITE_KEM, prk, "sk", EMPTY, 32);
  return { privateKey, publicKey: x25519PublicKey(privateKey) };
}

function extractAndExpand(dhValue: Uint8Array, kemContext: Uint8Array): Bytes {
  const prk = labeledExtract(SUITE_KEM, EMPTY, "eae_prk", dhValue);
  return labeledExpand(SUITE_KEM, prk, "shared_secret", kemContext, N_SECRET);
}

/** Contexto de cifrado (RFC 9180 §5.2): nonce = base_nonce XOR seq. */
export class HPKEContext {
  #seq = 0n;

  constructor(
    readonly sharedSecret: Bytes,
    readonly keyScheduleContext: Bytes,
    readonly secret: Bytes,
    readonly key: Bytes,
    readonly baseNonce: Bytes,
    readonly exporterSecret: Bytes,
  ) {}

  #nonce(): Bytes {
    const seq = new Uint8Array(N_NONCE);
    new DataView(seq.buffer).setBigUint64(4, this.#seq, false);
    return seq.map((b, i) => b ^ this.baseNonce[i]!);
  }

  seal(plaintext: Uint8Array, aad: Uint8Array = EMPTY): Bytes {
    const out = chacha20poly1305(this.key, this.#nonce(), aad).encrypt(plaintext) as Bytes;
    this.#seq += 1n;
    return out;
  }

  open(ciphertext: Uint8Array, aad: Uint8Array = EMPTY): Bytes {
    let out: Bytes;
    try {
      out = chacha20poly1305(this.key, this.#nonce(), aad).decrypt(ciphertext) as Bytes;
    } catch {
      throw new HPKEError("open failed");
    }
    this.#seq += 1n;
    return out;
  }
}

function keySchedule(sharedSecret: Bytes, info: Uint8Array): HPKEContext {
  // Modo auth: psk y psk_id vacíos.
  const pskIdHash = labeledExtract(SUITE_HPKE, EMPTY, "psk_id_hash", EMPTY);
  const infoHash = labeledExtract(SUITE_HPKE, EMPTY, "info_hash", info);
  const context = concat(Uint8Array.of(MODE_AUTH), pskIdHash, infoHash);
  const secret = labeledExtract(SUITE_HPKE, sharedSecret, "secret", EMPTY);
  return new HPKEContext(
    sharedSecret, context, secret,
    labeledExpand(SUITE_HPKE, secret, "key", context, N_KEY),
    labeledExpand(SUITE_HPKE, secret, "base_nonce", context, N_NONCE),
    labeledExpand(SUITE_HPKE, secret, "exp", context, 32),
  );
}

/** SetupAuthS. `ephemeral` fijo solo para los vectores: en producción sale al azar. */
export function setupAuthS(recipientPublic: Uint8Array, info: Uint8Array, senderPrivate: Uint8Array,
                           ephemeral: Uint8Array = generateX25519()): { enc: Bytes; context: HPKEContext } {
  const enc = x25519PublicKey(ephemeral);
  const dhValue = concat(dh(ephemeral, recipientPublic), dh(senderPrivate, recipientPublic));
  const kemContext = concat(enc, recipientPublic, x25519PublicKey(senderPrivate));
  return { enc, context: keySchedule(extractAndExpand(dhValue, kemContext), info) };
}

/** SetupAuthR. */
export function setupAuthR(enc: Uint8Array, recipientPrivate: Uint8Array, info: Uint8Array,
                           senderPublic: Uint8Array): HPKEContext {
  if (enc.length !== N_ENC) throw new HPKEError("bad enc");
  const dhValue = concat(dh(recipientPrivate, enc), dh(recipientPrivate, senderPublic));
  const kemContext = concat(enc, x25519PublicKey(recipientPrivate), senderPublic);
  return keySchedule(extractAndExpand(dhValue, kemContext), info);
}

// --- El sobre de PRBar (SealedEnvelope y Padding de Sealed.swift) ---

export const PADDING_BLOCK = 256;

/** `info` del push: `"PRBar push v1|<cuenta>|<dispositivo>"` (SealedInfo.push). */
export function pushInfo(account: string, device: string): Bytes {
  return utf8(`PRBar push v1|${account}|${device}`);
}

/** `info` del buzón: `"PRBar mailbox v1|<cuenta>|<dispositivo>|<ranura>"` (SealedInfo.mailbox). */
export function mailboxInfo(account: string, device: string, slot: string): Bytes {
  return utf8(`PRBar mailbox v1|${account}|${device}|${slot}`);
}

/** `len (u32 BE) ‖ datos ‖ ceros` hasta un múltiplo de `block`: el tamaño cifrado solo deja ver el bloque. */
export function pad(data: Uint8Array, block: number): Bytes {
  const body = concat(u32BE(data.length), data);
  const remainder = body.length % block;
  return remainder === 0 ? body : concat(body, new Uint8Array(block - remainder));
}

export function unpad(data: Uint8Array): Bytes {
  if (data.length < 4) throw new HPKEError("malformed");
  const length = readU32BE(data, 0);
  if (length > data.length - 4) throw new HPKEError("malformed");
  for (let i = 4 + length; i < data.length; i++) if (data[i] !== 0) throw new HPKEError("malformed");
  return data.slice(4, 4 + length);
}

/** `enc (32) ‖ ciphertext` del texto rellenado a 256, sin datos asociados. */
export function sealEnvelope(plaintext: Uint8Array, senderPrivate: Uint8Array, recipientPublic: Uint8Array,
                             info: Uint8Array, ephemeral?: Uint8Array): Bytes {
  const { enc, context } = setupAuthS(recipientPublic, info, senderPrivate, ephemeral);
  return concat(enc, context.seal(pad(plaintext, PADDING_BLOCK)));
}

export function openEnvelope(envelope: Uint8Array, recipientPrivate: Uint8Array, senderPublic: Uint8Array,
                             info: Uint8Array): Bytes {
  if (envelope.length < N_ENC + N_TAG + 4) throw new HPKEError("malformed");
  const context = setupAuthR(envelope.slice(0, N_ENC), recipientPrivate, info, senderPublic);
  return unpad(context.open(envelope.slice(N_ENC)));
}

/** `collapse` y `thread` opacos (PushIdentifiers de Sealed.swift): `pushIdKey` = HKDF-SHA256 (sal vacía, info
 *  "PRBar push ids v1") del secreto X25519 estático entre `macSealKey` y `devicePushKey`; HMAC de las partes unidas
 *  con 0x00. */
export function pushIdentifiers(ownPrivate: Uint8Array, otherPublic: Uint8Array) {
  const key = hkdf(sha256, dh(ownPrivate, otherPublic), EMPTY, utf8("PRBar push ids v1"), 32);
  const mac = (parts: string[]) => hmac(sha256, key, utf8(parts.join("\u0000")));
  return {
    /** 64 caracteres hex (32 bytes). */
    collapse: (kind: string, pr: string): string => toHex(mac(["collapse", kind, pr])),
    /** 32 caracteres hex (16 bytes). */
    thread: (pr: string): string => toHex(mac(["thread", pr]).slice(0, 16)),
  };
}
