import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { readU32BE, utf8 } from "./bytes";

// El código de 6 dígitos del emparejamiento (spec P.11, SAS.swift): `HKDF-SHA256(ikm: handshakeHash, sal vacía,
// info: "PRBar SAS v1", 4)` como u32 big endian `% 1 000 000`. Los dos lados lo derivan del hash de handshake de
// Noise IKpsk2: si un tercero se metió en el medio, los hashes (y casi seguro los códigos) difieren.

export function sasCode(handshakeHash: Uint8Array): string {
  const bytes = hkdf(sha256, handshakeHash, new Uint8Array(0), utf8("PRBar SAS v1"), 4);
  return String(readU32BE(bytes, 0) % 1_000_000).padStart(6, "0");
}

/** `"123 456"`. */
export function sasDisplay(code: string): string {
  return `${code.slice(0, 3)} ${code.slice(3)}`;
}
