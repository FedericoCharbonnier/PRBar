import { b64urlDecode } from "../crypto/b64";
import { openEnvelope, PADDING_BLOCK, pushInfo } from "../crypto/hpke";
import { deepLinkToHash } from "../protocol/deepLinks";
import { isObject, parseISODate, parseJSONBytes } from "../protocol/json";
import { cleanText, displayName } from "../protocol/text";
import type { PushKeys } from "../store/keys";

// Lo que hace el service worker con un push (spec W.6 y P.9, como PushOpener de la app nativa), como función pura:
// payload de Web Push → lo que se muestra. El relay arma `{"v":1,"e":<sobre HPKE en b64url>,"c":…,"th":…}`; el sobre
// se abre con `devicePushKey` (remitente `macSealKey`, `info = "PRBar push v1|<cuenta>|<dispositivo>"`). Siempre hay
// algo que mostrar (iOS corta las suscripciones que reciben pushes sin notificación): si no abre, es viejo (más de
// 24 h o más de 10 min en el futuro) o ya se vio, el genérico "PRBar — New activity on your Mac". Nunca se muestra
// texto sin descifrar.

export interface PushNotification {
  title: string;
  body: string;
  /** Agrupa y reemplaza: el `threadId` del PR. */
  tag: string;
  /** La ruta por hash a abrir (`#/pr/acme/api/7/respond`). */
  deepLink: string;
  badge?: number;
  /** El id del push: anotarlo en `SeenIds` después de mostrarlo. Ausente en el genérico. */
  id?: string;
}

export const GENERIC_PUSH: PushNotification = Object.freeze({
  title: "PRBar", body: "New activity on your Mac", tag: "prbar", deepLink: "#/home",
});

export const PUSH_MAX_AGE_MS = 24 * 3_600_000;
export const PUSH_MAX_SKEW_MS = 10 * 60_000;
/** El texto plano rellenado entra en 2 048 bytes (W.6): el sobre es `enc(32) ‖ ciphertext ‖ tag(16)`. */
const MAX_PADDED_PLAINTEXT = 2048;
const MAX_ENVELOPE = 32 + MAX_PADDED_PLAINTEXT + 16;

export function openPush(payloadJSON: string, keys: PushKeys | null, now: number,
                         seen: { has(id: string): boolean }): PushNotification {
  if (!keys) return { ...GENERIC_PUSH };
  try {
    const outer: unknown = JSON.parse(payloadJSON);
    if (!isObject(outer) || outer.v !== 1 || typeof outer.e !== "string") return { ...GENERIC_PUSH };
    if (outer.e.length > Math.ceil((MAX_ENVELOPE * 4) / 3)) return { ...GENERIC_PUSH };
    const envelope = b64urlDecode(outer.e);
    if (envelope.length > MAX_ENVELOPE || (envelope.length - 48) % PADDING_BLOCK !== 0) return { ...GENERIC_PUSH };
    const plaintext = openEnvelope(envelope, keys.devicePush, keys.macSeal, pushInfo(keys.account, keys.device));
    const p = parseJSONBytes(plaintext);
    if (!isObject(p) || p.v !== 1) return { ...GENERIC_PUSH };
    const { id, title, body, threadId, deepLink, badge } = p;
    if (typeof id !== "string" || id.length === 0 || typeof title !== "string" || typeof body !== "string"
        || typeof threadId !== "string" || typeof deepLink !== "string") return { ...GENERIC_PUSH };
    const created = parseISODate(p.createdAt);
    if (created === null || now - created > PUSH_MAX_AGE_MS || created - now > PUSH_MAX_SKEW_MS) {
      return { ...GENERIC_PUSH };
    }
    if (seen.has(id)) return { ...GENERIC_PUSH };
    // La Mac ya limpió los textos; se vuelven a pasar por el mismo filtro igual.
    const notification: PushNotification = {
      title: displayName(title, 200) || GENERIC_PUSH.title,
      body: cleanText(body),
      tag: displayName(threadId, 200) || GENERIC_PUSH.tag,
      // Un link que no es destino de una notificación (`prbar://pair`, otro esquema) abre Home.
      deepLink: deepLinkToHash(deepLink) ?? GENERIC_PUSH.deepLink,
      id,
    };
    if (typeof badge === "number" && Number.isSafeInteger(badge) && badge >= 0) notification.badge = badge;
    return notification;
  } catch {
    return { ...GENERIC_PUSH };
  }
}
