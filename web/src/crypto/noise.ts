import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { concat, utf8, type Bytes } from "./bytes";
import { generateX25519, x25519DH, x25519PublicKey } from "./curves";

// Noise Protocol Framework (rev. 34), solo lo que usa PRBar: `Noise_KK_25519_ChaChaPoly_SHA256` (sesiones) y
// `Noise_IKpsk2_25519_ChaChaPoly_SHA256` (emparejamiento). Spec P.5. Copia de Noise.swift: mismos nombres
// (CipherState, SymmetricState, HandshakeState) y mismos errores, para poder compararlos línea por línea.

export type NoiseErrorCode =
  /** El contador llegó a 2⁶⁴−1: la sesión no se puede seguir usando. */
  | "nonceExhausted"
  /** Un mensaje de Noise mide como máximo 65 535 bytes. */
  | "messageTooLarge"
  /** No autenticó (byte cambiado, mensaje repetido o fuera de orden, otra clave). La sesión queda inutilizable. */
  | "decryptFailed"
  /** Mensaje corto o con un formato imposible. */
  | "malformed"
  /** Se llamó fuera de turno, después de un error o antes de terminar el handshake. */
  | "invalidState"
  /** Falta (o sobra) una clave o el psk que el patrón necesita. */
  | "invalidConfiguration";

export class NoiseError extends Error {
  constructor(readonly code: NoiseErrorCode) {
    super(`noise: ${code}`);
  }
}

const DH_LEN = 32;
const HASH_LEN = 32;
const TAG_LEN = 16;
export const NOISE_MAX_MESSAGE = 65_535;
const NONCE_MAX = (1n << 64n) - 1n;
const EMPTY = new Uint8Array(0);

function hash(data: Uint8Array): Bytes {
  return sha256(data) as Bytes;
}

function mac(key: Uint8Array, data: Uint8Array): Bytes {
  return hmac(sha256, key, data) as Bytes;
}

/** HKDF de Noise (sección 4.3): `temp = HMAC(ck, ikm)`, `out1 = HMAC(temp, 0x01)`, `out2 = HMAC(temp, out1 ‖ 0x02)`,
 *  `out3 = HMAC(temp, out2 ‖ 0x03)`. */
function hkdf(chainingKey: Uint8Array, ikm: Uint8Array, outputs: 2 | 3): Bytes[] {
  const temp = mac(chainingKey, ikm);
  const out1 = mac(temp, Uint8Array.of(1));
  const out2 = mac(temp, concat(out1, Uint8Array.of(2)));
  if (outputs === 2) return [out1, out2];
  return [out1, out2, mac(temp, concat(out2, Uint8Array.of(3)))];
}

function dh(privateKey: Uint8Array, publicKey: Uint8Array): Bytes {
  try {
    return x25519DH(privateKey, publicKey);
  } catch {
    throw new NoiseError("decryptFailed");
  }
}

/** Clave + contador de 64 bits. Nonce de ChaChaPoly = 4 bytes en cero ‖ `n` en little endian (sección 5.1 y 12.3). */
export class CipherState {
  #key: Bytes | null;
  /** El próximo nonce. */
  #n = 0n;
  /** Un descifrado falló: el estado queda inutilizable (spec P.5: la sesión se cierra y se hace otro handshake). */
  #broken = false;

  constructor(key: Bytes | null = null) {
    this.#key = key;
  }

  get n(): bigint {
    return this.#n;
  }

  get isBroken(): boolean {
    return this.#broken;
  }

  get hasKey(): boolean {
    return this.#key !== null;
  }

  #nonce(): Bytes {
    const nonce = new Uint8Array(12);
    new DataView(nonce.buffer).setBigUint64(4, this.#n, true);
    return nonce;
  }

  encryptWithAd(ad: Uint8Array, plaintext: Uint8Array): Bytes {
    if (this.#broken) throw new NoiseError("invalidState");
    if (!this.#key) return Uint8Array.from(plaintext);
    // 2⁶⁴−1 está reservado (sección 5.1): no se usa como nonce.
    if (this.#n === NONCE_MAX) throw new NoiseError("nonceExhausted");
    const out = chacha20poly1305(this.#key, this.#nonce(), ad).encrypt(plaintext) as Bytes;
    this.#n += 1n;
    return out;
  }

  decryptWithAd(ad: Uint8Array, ciphertext: Uint8Array): Bytes {
    if (this.#broken) throw new NoiseError("invalidState");
    if (!this.#key) return Uint8Array.from(ciphertext);
    if (this.#n === NONCE_MAX) throw new NoiseError("nonceExhausted");
    if (ciphertext.length < TAG_LEN) {
      this.#broken = true;
      throw new NoiseError("decryptFailed");
    }
    try {
      const out = chacha20poly1305(this.#key, this.#nonce(), ad).decrypt(ciphertext) as Bytes;
      this.#n += 1n;
      return out;
    } catch {
      // El contador no avanza (sección 5.1) y el estado no se vuelve a usar.
      this.#broken = true;
      throw new NoiseError("decryptFailed");
    }
  }

  /** Transporte: un mensaje de Noise entero (texto plano + 16 de tag ≤ 65 535 bytes), sin datos asociados. */
  encrypt(plaintext: Uint8Array): Bytes {
    if (plaintext.length + TAG_LEN > NOISE_MAX_MESSAGE) throw new NoiseError("messageTooLarge");
    if (!this.hasKey) throw new NoiseError("invalidState");
    return this.encryptWithAd(EMPTY, plaintext);
  }

  decrypt(ciphertext: Uint8Array): Bytes {
    if (ciphertext.length > NOISE_MAX_MESSAGE) {
      this.#broken = true;
      throw new NoiseError("messageTooLarge");
    }
    if (!this.hasKey) throw new NoiseError("invalidState");
    return this.decryptWithAd(EMPTY, ciphertext);
  }

  /** Solo para los tests: fija el contador (para probar el tope de 2⁶⁴−1). */
  _setNonceForTesting(n: bigint): void {
    this.#n = n;
  }
}

/** `ck`, `h` y el `CipherState` del handshake (sección 5.2). */
class SymmetricState {
  ck: Bytes;
  h: Bytes;
  cipher = new CipherState();

  constructor(protocolName: string) {
    const name = utf8(protocolName);
    this.h = name.length <= HASH_LEN ? concat(name, new Uint8Array(HASH_LEN - name.length)) : hash(name);
    this.ck = this.h;
  }

  mixKey(ikm: Uint8Array): void {
    const [ck, k] = hkdf(this.ck, ikm, 2);
    this.ck = ck!;
    this.cipher = new CipherState(k!);
  }

  mixHash(data: Uint8Array): void {
    this.h = hash(concat(this.h, data));
  }

  mixKeyAndHash(ikm: Uint8Array): void {
    const [ck, th, k] = hkdf(this.ck, ikm, 3);
    this.ck = ck!;
    this.mixHash(th!);
    this.cipher = new CipherState(k!);
  }

  encryptAndHash(plaintext: Uint8Array): Bytes {
    const ciphertext = this.cipher.encryptWithAd(this.h, plaintext);
    this.mixHash(ciphertext);
    return ciphertext;
  }

  decryptAndHash(ciphertext: Uint8Array): Bytes {
    const plaintext = this.cipher.decryptWithAd(this.h, ciphertext);
    this.mixHash(ciphertext);
    return plaintext;
  }

  split(): [CipherState, CipherState] {
    const [k1, k2] = hkdf(this.ck, EMPTY, 2);
    return [new CipherState(k1!), new CipherState(k2!)];
  }
}

/** `kk`: `-> s`, `<- s` / `-> e, es, ss` / `<- e, ee, se`. `ikpsk2`: `<- s` / `-> e, es, s, ss` / `<- e, ee, se, psk`. */
export type NoisePattern = "kk" | "ikpsk2";

type Token = "e" | "s" | "ee" | "es" | "se" | "ss" | "psk";

const PROTOCOL_NAME: Record<NoisePattern, string> = {
  kk: "Noise_KK_25519_ChaChaPoly_SHA256",
  ikpsk2: "Noise_IKpsk2_25519_ChaChaPoly_SHA256",
};

const MESSAGES: Record<NoisePattern, Token[][]> = {
  kk: [["e", "es", "ss"], ["e", "ee", "se"]],
  ikpsk2: [["e", "es", "s", "ss"], ["e", "ee", "se", "psk"]],
};

/** Las dos direcciones del transporte, ya orientadas según el rol. */
export interface NoiseTransport {
  send: CipherState;
  receive: CipherState;
}

export interface NoiseHandshakeOptions {
  pattern: NoisePattern;
  initiator: boolean;
  prologue: Uint8Array;
  /** Privada X25519 (32 bytes). */
  localStatic: Uint8Array;
  /** Pública X25519 del otro lado: obligatoria en KK; en IKpsk2 solo la tiene el iniciador. */
  remoteStatic?: Uint8Array | null;
  /** 32 bytes; solo IKpsk2. */
  psk?: Uint8Array | null;
  /** Solo para los vectores de prueba: en producción la efímera sale siempre al azar. */
  fixedEphemeral?: Uint8Array | null;
}

/** `HandshakeState` (sección 5.3) para KK e IKpsk2. Un error al leer o escribir deja el handshake inutilizable. */
export class NoiseHandshake {
  readonly pattern: NoisePattern;
  readonly initiator: boolean;
  #symmetric: SymmetricState;
  #localStatic: Bytes;
  #localEphemeral: Bytes | null = null;
  #fixedEphemeral: Bytes | null;
  #remoteStatic: Bytes | null;
  #remoteEphemeral: Bytes | null = null;
  #psk: Bytes | null;
  #messageIndex = 0;
  #failed = false;

  constructor(options: NoiseHandshakeOptions) {
    const { pattern, initiator } = options;
    const remoteStatic = options.remoteStatic ? Uint8Array.from(options.remoteStatic) : null;
    const psk = options.psk ? Uint8Array.from(options.psk) : null;
    if (options.localStatic.length !== DH_LEN || (remoteStatic && remoteStatic.length !== DH_LEN)) {
      throw new NoiseError("invalidConfiguration");
    }
    if (pattern === "kk") {
      if (!remoteStatic || psk) throw new NoiseError("invalidConfiguration");
    } else {
      // El iniciador conoce la estática del respondedor (pre-mensaje `<- s`); el respondedor la aprende.
      if ((remoteStatic !== null) !== initiator || psk?.length !== 32) throw new NoiseError("invalidConfiguration");
    }
    this.pattern = pattern;
    this.initiator = initiator;
    this.#localStatic = Uint8Array.from(options.localStatic);
    this.#remoteStatic = remoteStatic;
    this.#psk = psk;
    this.#fixedEphemeral = options.fixedEphemeral ? Uint8Array.from(options.fixedEphemeral) : null;
    this.#symmetric = new SymmetricState(PROTOCOL_NAME[pattern]);
    this.#symmetric.mixHash(options.prologue);
    // Pre-mensajes: primero los del iniciador, después los del respondedor.
    const localPublic = x25519PublicKey(this.#localStatic);
    const initiatorStatic = initiator ? localPublic : remoteStatic;
    const responderStatic = initiator ? remoteStatic : localPublic;
    if (pattern === "kk") this.#symmetric.mixHash(initiatorStatic!);
    this.#symmetric.mixHash(responderStatic!);
  }

  get isComplete(): boolean {
    return this.#messageIndex === MESSAGES[this.pattern].length && !this.#failed;
  }

  /** `h` al terminar: identifica la sesión (SAS, atestación de presencia). */
  get handshakeHash(): Bytes {
    return this.#symmetric.h;
  }

  /** La estática del otro lado (en IKpsk2, el respondedor la conoce después del primer mensaje). */
  get remoteStaticKey(): Bytes | null {
    return this.#remoteStatic;
  }

  get #isMyTurn(): boolean {
    return (this.#messageIndex % 2 === 0) === this.initiator;
  }

  get #usesPSK(): boolean {
    return this.pattern === "ikpsk2";
  }

  writeMessage(payload: Uint8Array = EMPTY): Bytes {
    if (this.#failed || this.#messageIndex >= MESSAGES[this.pattern].length || !this.#isMyTurn) {
      throw new NoiseError("invalidState");
    }
    try {
      const parts: Uint8Array[] = [];
      for (const token of MESSAGES[this.pattern][this.#messageIndex]!) {
        if (token === "e") {
          const e = this.#fixedEphemeral ?? generateX25519();
          this.#localEphemeral = e;
          const pub = x25519PublicKey(e);
          parts.push(pub);
          this.#symmetric.mixHash(pub);
          if (this.#usesPSK) this.#symmetric.mixKey(pub);
        } else if (token === "s") {
          parts.push(this.#symmetric.encryptAndHash(x25519PublicKey(this.#localStatic)));
        } else {
          this.#mixDH(token);
        }
      }
      parts.push(this.#symmetric.encryptAndHash(payload));
      const out = concat(...parts);
      if (out.length > NOISE_MAX_MESSAGE) throw new NoiseError("messageTooLarge");
      this.#messageIndex += 1;
      return out;
    } catch (error) {
      this.#failed = true;
      throw error instanceof NoiseError ? error : new NoiseError("decryptFailed");
    }
  }

  readMessage(message: Uint8Array): Bytes {
    if (this.#failed || this.#messageIndex >= MESSAGES[this.pattern].length || this.#isMyTurn) {
      throw new NoiseError("invalidState");
    }
    try {
      if (message.length > NOISE_MAX_MESSAGE) throw new NoiseError("messageTooLarge");
      let offset = 0;
      const take = (count: number): Bytes => {
        if (message.length - offset < count) throw new NoiseError("malformed");
        const out = message.slice(offset, offset + count);
        offset += count;
        return out;
      };
      for (const token of MESSAGES[this.pattern][this.#messageIndex]!) {
        if (token === "e") {
          const raw = take(DH_LEN);
          this.#remoteEphemeral = raw;
          this.#symmetric.mixHash(raw);
          if (this.#usesPSK) this.#symmetric.mixKey(raw);
        } else if (token === "s") {
          const length = DH_LEN + (this.#symmetric.cipher.hasKey ? TAG_LEN : 0);
          this.#remoteStatic = this.#symmetric.decryptAndHash(take(length));
        } else {
          this.#mixDH(token);
        }
      }
      const payload = this.#symmetric.decryptAndHash(message.slice(offset));
      this.#messageIndex += 1;
      return payload;
    } catch (error) {
      this.#failed = true;
      throw error instanceof NoiseError ? error : new NoiseError("decryptFailed");
    }
  }

  #mixDH(token: Token): void {
    const need = (value: Bytes | null): Bytes => {
      if (!value) throw new NoiseError("invalidState");
      return value;
    };
    const s = this.#symmetric;
    switch (token) {
      case "ee":
        s.mixKey(dh(need(this.#localEphemeral), need(this.#remoteEphemeral)));
        break;
      case "es":
        s.mixKey(this.initiator ? dh(need(this.#localEphemeral), need(this.#remoteStatic))
                                : dh(this.#localStatic, need(this.#remoteEphemeral)));
        break;
      case "se":
        s.mixKey(this.initiator ? dh(this.#localStatic, need(this.#remoteEphemeral))
                                : dh(need(this.#localEphemeral), need(this.#remoteStatic)));
        break;
      case "ss":
        s.mixKey(dh(this.#localStatic, need(this.#remoteStatic)));
        break;
      case "psk":
        s.mixKeyAndHash(need(this.#psk));
        break;
      default:
        throw new NoiseError("invalidState");
    }
  }

  /** Las claves de transporte (`Split()`), orientadas: el iniciador manda con la primera. */
  split(): NoiseTransport {
    if (!this.isComplete) throw new NoiseError("invalidState");
    const [c1, c2] = this.#symmetric.split();
    return this.initiator ? { send: c1, receive: c2 } : { send: c2, receive: c1 };
  }
}

/** Prólogo de la sesión KK (RemotePrologue.session): `"PRBar Remote v1" ‖ cuenta ‖ 0x00 ‖ dispositivo`. */
export function sessionPrologue(account: string, device: string): Bytes {
  return concat(utf8("PRBar Remote v1"), utf8(account), Uint8Array.of(0), utf8(device));
}

/** Prólogo del emparejamiento IKpsk2 (RemotePrologue.pairing): `"PRBar Pair v1" ‖ cuenta ‖ 0x00 ‖ id`. */
export function pairingPrologue(account: string, pairing: string): Bytes {
  return concat(utf8("PRBar Pair v1"), utf8(account), Uint8Array.of(0), utf8(pairing));
}
