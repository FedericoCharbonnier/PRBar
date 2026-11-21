import type { Bytes } from "./bytes";

// base64url sin relleno (RFC 4648 §5), estricto como Base64URL.swift: rechaza `=`, `+`, `/`, espacios, largos
// imposibles y bits sobrantes distintos de cero, así cada valor tiene una sola escritura (importa para ids y claves
// que se comparan como texto). También base64 estándar con relleno: así codifica
// Swift los `Data` de los tipos Codable (como `cmd` del `req`).

const STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

function table(alphabet: string): Int16Array {
  const t = new Int16Array(128).fill(-1);
  for (let i = 0; i < alphabet.length; i++) t[alphabet.charCodeAt(i)] = i;
  return t;
}
const STD_TABLE = table(STD);
const URL_TABLE = table(URL);

function encode(data: Uint8Array, alphabet: string, pad: boolean): string {
  let out = "";
  let i = 0;
  for (; i + 3 <= data.length; i += 3) {
    const n = (data[i]! << 16) | (data[i + 1]! << 8) | data[i + 2]!;
    out += alphabet[(n >> 18) & 63]! + alphabet[(n >> 12) & 63]! + alphabet[(n >> 6) & 63]! + alphabet[n & 63]!;
  }
  const rest = data.length - i;
  if (rest === 1) {
    const n = data[i]! << 16;
    out += alphabet[(n >> 18) & 63]! + alphabet[(n >> 12) & 63]! + (pad ? "==" : "");
  } else if (rest === 2) {
    const n = (data[i]! << 16) | (data[i + 1]! << 8);
    out += alphabet[(n >> 18) & 63]! + alphabet[(n >> 12) & 63]! + alphabet[(n >> 6) & 63]! + (pad ? "=" : "");
  }
  return out;
}

/** Decodifica sin relleno; tira si algo no es canónico. */
function decodeUnpadded(text: string, lookup: Int16Array): Bytes {
  if (text.length % 4 === 1) throw new Error("invalid base64");
  const values = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    const v = c < 128 ? lookup[c]! : -1;
    if (v < 0) throw new Error("invalid base64");
    values[i] = v;
  }
  const out = new Uint8Array(Math.floor((text.length * 6) / 8));
  let buffer = 0;
  let bits = 0;
  let o = 0;
  for (const v of values) {
    buffer = ((buffer << 6) | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (buffer >> bits) & 0xff;
    }
  }
  // Los bits que sobran tienen que ser cero (si no, dos textos darían los mismos bytes).
  if ((buffer & ((1 << bits) - 1)) !== 0) throw new Error("invalid base64");
  return out;
}

export function b64urlEncode(data: Uint8Array): string {
  return encode(data, URL, false);
}

export function b64urlDecode(text: string): Bytes {
  return decodeUnpadded(text, URL_TABLE);
}

/** base64 estándar con relleno. */
export function b64Encode(data: Uint8Array): string {
  return encode(data, STD, true);
}

/** base64 estándar: exige el relleno exacto (largo múltiplo de 4). */
export function b64Decode(text: string): Bytes {
  if (text.length % 4 !== 0) throw new Error("invalid base64");
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  return decodeUnpadded(text.slice(0, text.length - padding), STD_TABLE);
}
