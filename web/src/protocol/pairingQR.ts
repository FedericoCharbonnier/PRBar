import { b64urlDecode, b64urlEncode } from "../crypto/b64";
import type { Bytes } from "../crypto/bytes";
import { displayName } from "./text";

// El QR de emparejamiento (spec W.4.4, PairingQR.swift):
// `https://<host>/#pair?v=1&r=<host>&a=<accountId>&p=<pairingId>&k=<ps b64url>&m=<macStatic b64url>&n=<nombre>`.
// El fragmento `#` nunca llega al servidor: lo lee la web app instalada (escaneado o pegado en "Paste code").

export interface PairingQR {
  relayHost: string;
  accountId: string;
  pairingId: string;
  /** `ps`: 32 bytes de los que salen `pairAuthKey` y el psk de Noise. Es el secreto del QR. */
  secret: Bytes;
  /** `macStatic.pub` (X25519, 32 bytes). */
  macStatic: Bytes;
  macName: string;
}

export class PairingQRError extends Error {
  constructor(readonly reason: string) {
    super(`pairing link: ${reason}`);
  }
}

export const PAIRING_QR_MAX_LENGTH = 512;
const MAX_NAME_LENGTH = 64;
const BASE32 = /^[a-z2-7]+$/;

/** Solo letras, dígitos y `-._~` quedan sin codificar (`encodeURIComponent` además deja `!'()*`). */
function encode(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function pairingURL(qr: PairingQR): string {
  const items: [string, string][] = [
    ["v", "1"], ["r", qr.relayHost], ["a", qr.accountId], ["p", qr.pairingId], ["k", b64urlEncode(qr.secret)],
    ["m", b64urlEncode(qr.macStatic)], ["n", qr.macName],
  ];
  return `https://${qr.relayHost}/#pair?` + items.map(([k, v]) => `${k}=${encode(v)}`).join("&");
}

/** Un nombre de host (letras, dígitos, `-`, `.`) con `:puerto` opcional, sin esquema, ruta ni usuario. Una IP literal
 *  (todo dígitos y puntos) solo si `allowIP`. */
export function isValidHost(text: string, allowIP: boolean): boolean {
  let host = text;
  const colon = text.lastIndexOf(":");
  if (colon >= 0) {
    const port = text.slice(colon + 1);
    if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65_535) return false;
    host = text.slice(0, colon);
  }
  if (host.length === 0 || host.length > 253 || host.startsWith(".") || host.endsWith(".") || host.startsWith("-")) {
    return false;
  }
  if (!/^[A-Za-z0-9.-]+$/.test(host)) return false;
  return allowIP || /[A-Za-z]/.test(host);
}

/** Parsea el texto escaneado o pegado; ignora espacios y saltos alrededor. `allowInsecure` acepta una IP literal
 *  (el relay local de los tests). */
export function parsePairingURL(input: string, options: { allowInsecure?: boolean } = {}): PairingQR {
  const text = input.trim();
  if ([...text].length > PAIRING_QR_MAX_LENGTH) throw new PairingQRError("too long");
  const marker = "/#pair?";
  const at = text.indexOf(marker);
  if (!text.startsWith("https://") || at < 0) throw new PairingQRError("not a pairing link");
  const linkHost = text.slice(8, at);
  const values = new Map<string, string>();
  for (const pair of text.slice(at + marker.length).split("&")) {
    const eq = pair.indexOf("=");
    if (eq < 0) throw new PairingQRError("bad parameter");
    let key: string;
    let value: string;
    try {
      key = decodeURIComponent(pair.slice(0, eq));
      value = decodeURIComponent(pair.slice(eq + 1));
    } catch {
      throw new PairingQRError("bad parameter");
    }
    if (values.has(key)) throw new PairingQRError(`repeated ${key}`);
    values.set(key, value);
  }
  if (values.get("v") !== "1") throw new PairingQRError("unsupported version");
  const host = values.get("r");
  if (host === undefined || !isValidHost(host, options.allowInsecure ?? false)) throw new PairingQRError("bad relay");
  // La página que abre el link es la del relay del QR: un link a otro sitio con `r` de este no vale.
  if (linkHost !== host) throw new PairingQRError("relay doesn't match the link");
  const account = values.get("a");
  if (account === undefined || account.length !== 26 || !BASE32.test(account)) throw new PairingQRError("bad account");
  const pairing = values.get("p");
  if (pairing === undefined || pairing.length !== 16 || !BASE32.test(pairing)) {
    throw new PairingQRError("bad pairing id");
  }
  const key = (name: string, what: string): Bytes => {
    try {
      const bytes = b64urlDecode(values.get(name) ?? "");
      if (bytes.length === 32) return bytes;
    } catch {
      // Cae al error de abajo.
    }
    throw new PairingQRError(what);
  };
  const secret = key("k", "bad secret");
  const macStatic = key("m", "bad mac key");
  const raw = values.get("n") ?? "";
  if ([...raw].length > MAX_NAME_LENGTH) throw new PairingQRError("bad name");
  // Cualquiera puede mandar un link: el nombre que se muestra es una línea plana (revisión L5).
  const name = displayName(raw, MAX_NAME_LENGTH);
  return { relayHost: host, accountId: account, pairingId: pairing, secret, macStatic, macName: name || "Mac" };
}
