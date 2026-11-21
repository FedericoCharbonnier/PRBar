import { utf8, type Bytes } from "../crypto/bytes";

// JSON como lo escribe la Mac (`CommandProtocol.encoder` y `RelayMessage.encoder`: `.sortedKeys` y
// `.withoutEscapingSlashes`): claves ordenadas en todos los niveles, `/` sin escapar y sin espacios. Así lo que manda
// la web es byte a byte lo mismo que mandaría Swift (importa para `cmd`, que la Mac hashea tal cual llegó, P.8).

/** Un valor JSON cualquiera (`JSONValue` de PRBarWire). */
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value instanceof Uint8Array) throw new TypeError("encode bytes before writing JSON");
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      const field = (value as Record<string, unknown>)[key];
      // Un opcional ausente (`undefined`) no se escribe, como `encodeIfPresent`.
      if (field !== undefined) out[key] = sortKeys(field);
    }
    return out;
  }
  return value;
}

/** El texto JSON canónico de `value`. */
export function swiftJSON(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

export function swiftJSONBytes(value: unknown): Bytes {
  return utf8(swiftJSON(value));
}

const decoder = new TextDecoder("utf-8", { fatal: true });

/** Parsea UTF-8 estricto (un byte inválido es un error, no U+FFFD). */
export function parseJSONBytes(data: Uint8Array): unknown {
  return JSON.parse(decoder.decode(data));
}

/** Fecha ISO 8601 sin fracción, en UTC (`.iso8601` de Foundation): `2026-11-20T12:38:00Z`. */
export function isoDate(millis: number): string {
  return new Date(Math.floor(millis / 1000) * 1000).toISOString().replace(".000Z", "Z");
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

/** Milisegundos de una fecha ISO 8601 (la acepta con o sin fracción); `null` si no es una. */
export function parseISODate(text: unknown): number | null {
  if (typeof text !== "string" || !ISO.test(text)) return null;
  const millis = Date.parse(text);
  return Number.isFinite(millis) ? millis : null;
}

// --- Validación liviana de lo que llega (la Mac es la fuente, pero el JSON puede venir roto) ---

export class DecodeError extends Error {
  constructor(message: string) {
    super(`decode: ${message}`);
  }
}

export function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) && !(value instanceof Uint8Array);
}

export function expectObject(value: unknown, what: string): Record<string, unknown> {
  if (!isObject(value)) throw new DecodeError(`${what} is not an object`);
  return value;
}

export function expectString(value: unknown, what: string): string {
  if (typeof value !== "string") throw new DecodeError(`${what} is not a string`);
  return value;
}

export function expectInt(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new DecodeError(`${what} is not an integer`);
  return value;
}

export function expectBool(value: unknown, what: string): boolean {
  if (typeof value !== "boolean") throw new DecodeError(`${what} is not a boolean`);
  return value;
}

export function optionalString(value: unknown, what: string): string | undefined {
  return value === undefined || value === null ? undefined : expectString(value, what);
}
