import { ed25519, x25519 } from "@noble/curves/ed25519.js";
import { randomBytes, type Bytes } from "./bytes";

// Claves X25519 (Noise, HPKE) y Ed25519 (auth del relay): privadas y públicas de 32 bytes, como `rawRepresentation`
// de CryptoKit.

export class DHError extends Error {
  constructor() {
    super("invalid X25519 key");
  }
}

export function generateX25519(): Bytes {
  return randomBytes(32);
}

export function x25519PublicKey(privateKey: Uint8Array): Bytes {
  return x25519.getPublicKey(privateKey) as Bytes;
}

/** X25519. Como CryptoKit, rechaza los puntos de orden bajo (secreto todo en cero) y los largos incorrectos. */
export function x25519DH(privateKey: Uint8Array, publicKey: Uint8Array): Bytes {
  if (privateKey.length !== 32 || publicKey.length !== 32) throw new DHError();
  let secret: Uint8Array;
  try {
    secret = x25519.getSharedSecret(privateKey, publicKey);
  } catch {
    throw new DHError();
  }
  let acc = 0;
  for (const b of secret) acc |= b;
  if (acc === 0) throw new DHError();
  return secret as Bytes;
}

export function generateEd25519(): Bytes {
  return randomBytes(32);
}

export function ed25519PublicKey(privateKey: Uint8Array): Bytes {
  return ed25519.getPublicKey(privateKey) as Bytes;
}

export function ed25519Sign(message: Uint8Array, privateKey: Uint8Array): Bytes {
  return ed25519.sign(message, privateKey) as Bytes;
}

export function ed25519Verify(signature: Uint8Array, message: Uint8Array, publicKey: Uint8Array): boolean {
  try {
    return ed25519.verify(signature, message, publicKey);
  } catch {
    return false;
  }
}
