import { hkdf } from "@noble/hashes/hkdf.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { concat, utf8, type Bytes } from "./bytes";
import { ed25519Sign, ed25519Verify } from "./curves";

// Autenticación ante el relay (spec P.4 y P.11): un dispositivo emparejado firma el desafío con su `deviceRelayKey`
// (Ed25519); un teléfono que se está emparejando prueba que tiene el secreto del QR con un HMAC.

/** `"PRBarRelayAuth v1\n" ‖ host ‖ "\n" ‖ cuenta ‖ "\n" ‖ cliente ‖ "\n" ‖ nonce` (RelayAuth.message). `host` es el
 *  host público del relay sin puerto: una firma no sirve en otro relay. */
export function relayAuthMessage(host: string, account: string, client: string, nonce: Uint8Array): Bytes {
  return concat(utf8(`PRBarRelayAuth v1\n${host}\n${account}\n${client}\n`), nonce);
}

/** Lo que se firma es el host sin `:puerto` (RelayTransport.swift). */
export function signedHost(host: string): string {
  return host.split(":")[0] ?? host;
}

/** `sig` del marco `auth`. `host` puede traer puerto: se quita antes de firmar. */
export function signRelayAuth(relayKey: Uint8Array, host: string, account: string, client: string,
                              nonce: Uint8Array): Bytes {
  return ed25519Sign(relayAuthMessage(signedHost(host), account, client, nonce), relayKey);
}

export function verifyRelayAuth(signature: Uint8Array, publicKey: Uint8Array, host: string, account: string,
                                client: string, nonce: Uint8Array): boolean {
  return ed25519Verify(signature, relayAuthMessage(signedHost(host), account, client, nonce), publicKey);
}

/** Lo que sale del secreto del QR (PairingSecrets de RemoteKeys.swift). El relay solo ve `authKey`; `psk` (el de
 *  Noise IKpsk2) nunca sale de los dos extremos. */
export function pairingSecrets(secret: Uint8Array): { authKey: Bytes; psk: Bytes } {
  const derive = (info: string) => hkdf(sha256, secret, new Uint8Array(0), utf8(info), 32) as Bytes;
  return { authKey: derive("PRBar relay pairing v1"), psk: derive("PRBar noise psk v1") };
}

/** `proof` del marco `auth` al emparejar: HMAC-SHA256(`pairAuthKey`, `nonce`). */
export function pairingProof(authKey: Uint8Array, nonce: Uint8Array): Bytes {
  return hmac(sha256, authKey, nonce) as Bytes;
}
