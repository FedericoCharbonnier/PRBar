// Utilidades de bytes (equivalen a Bytes.swift). Todo el código de cripto trabaja con `Uint8Array`.

export type Bytes = Uint8Array<ArrayBuffer>;

const encoder = new TextEncoder();

export function utf8(text: string): Bytes {
  return encoder.encode(text) as Bytes;
}

export function concat(...parts: Uint8Array[]): Bytes {
  let length = 0;
  for (const p of parts) length += p.length;
  const out = new Uint8Array(length);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

/** Hex en minúscula. */
export function toHex(data: Uint8Array): string {
  let out = "";
  for (const b of data) out += b.toString(16).padStart(2, "0");
  return out;
}

/** Acepta mayúsculas y minúsculas; tira con largo impar o un carácter que no es hex. */
export function fromHex(text: string): Bytes {
  if (text.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(text)) throw new Error("invalid hex");
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16);
  return out;
}

const U64_MAX = (1n << 64n) - 1n;

function toBigInt(value: number | bigint): bigint {
  if (typeof value === "number" && !Number.isSafeInteger(value)) throw new RangeError("not a safe integer");
  return BigInt(value);
}

/** `Data(uint64BE:)`: 8 bytes big endian. */
export function u64BE(value: number | bigint): Bytes {
  const v = toBigInt(value);
  if (v < 0n || v > U64_MAX) throw new RangeError("u64 out of range");
  const out = new Uint8Array(8);
  new DataView(out.buffer).setBigUint64(0, v, false);
  return out;
}

/** `Data(int64BE:)`: complemento a dos, 8 bytes big endian. */
export function i64BE(value: number | bigint): Bytes {
  const v = toBigInt(value);
  if (v < -(1n << 63n) || v >= 1n << 63n) throw new RangeError("i64 out of range");
  const out = new Uint8Array(8);
  new DataView(out.buffer).setBigInt64(0, v, false);
  return out;
}

export function u32BE(value: number): Bytes {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) throw new RangeError("u32 out of range");
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value, false);
  return out;
}

export function readU32BE(data: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > data.length) throw new RangeError("out of bounds");
  return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(offset, false);
}

/** Compara sin cortar en el primer byte distinto (el tiempo depende solo del largo, que no es secreto). */
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/** Bytes del CSPRNG del navegador. */
export function randomBytes(n: number): Bytes {
  const out = new Uint8Array(n);
  crypto.getRandomValues(out);
  return out;
}
