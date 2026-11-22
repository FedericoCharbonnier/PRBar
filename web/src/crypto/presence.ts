import { sha256 } from "@noble/hashes/sha2.js";
import { b64urlEncode } from "./b64";
import { concat, i64BE, u64BE, utf8, type Bytes } from "./bytes";

// Prueba de presencia v2 (spec W.5): el teléfono firma con una passkey (WebAuthn, Face ID) un desafío atado a la
// sesión de Noise, al id del pedido, a los bytes exactos del comando y a la hora. La Mac lo recalcula y verifica.

const LABEL = utf8("PRBarPresence v2");

/** `SHA256("PRBarPresence v2" ‖ sessionHash(32) ‖ reqId(u64 BE) ‖ SHA256(cmd) ‖ ts(i64 BE, ms))`. Es el
 *  `challenge` de `navigator.credentials.get`. */
export function presenceChallenge(sessionHash: Uint8Array, reqId: number | bigint, commandBytes: Uint8Array,
                                  tsMillis: number | bigint): Bytes {
  if (sessionHash.length !== 32) throw new RangeError("sessionHash must be 32 bytes");
  return sha256(concat(LABEL, sessionHash, u64BE(reqId), sha256(commandBytes), i64BE(tsMillis))) as Bytes;
}

/** Lo que devuelve la passkey, más los milisegundos que se firmaron. */
export interface PresenceProof {
  tsMillis: number;
  credentialId: Uint8Array;
  authenticatorData: Uint8Array;
  clientDataJSON: Uint8Array;
  /** ECDSA P-256 en DER, como la da WebAuthn. */
  signature: Uint8Array;
}

export interface PresenceProofJSON {
  v: 2;
  ts: number;
  credentialId: string;
  authenticatorData: string;
  clientDataJSON: string;
  signature: string;
}

/** Lo que va en el `req` (bytes en base64url). */
export function presenceProofJSON(proof: PresenceProof): PresenceProofJSON {
  return {
    v: 2,
    ts: proof.tsMillis,
    credentialId: b64urlEncode(proof.credentialId),
    authenticatorData: b64urlEncode(proof.authenticatorData),
    clientDataJSON: b64urlEncode(proof.clientDataJSON),
    signature: b64urlEncode(proof.signature),
  };
}
