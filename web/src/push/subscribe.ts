import { b64urlDecode } from "../crypto/b64";
import type { WebPushSubscriptionKeys } from "../transport/Transport";

// Web Push (spec W.6): la clave pública VAPID del relay (`GET /v1/vapid`), `pushManager.subscribe` y el registro en
// el relay por el WebSocket (marco `webpush`). Si el relay cambió su clave VAPID, la suscripción vieja ya no sirve:
// se da de baja y se hace otra. Se llama después del permiso y en cada arranque con el permiso dado (el relay pudo
// haber borrado la suscripción; el transporte la vuelve a mandar en cada conexión).

export interface PushSubscriptionLike {
  readonly endpoint: string;
  readonly options?: { applicationServerKey?: ArrayBuffer | null } | undefined;
  getKey(name: "p256dh" | "auth"): ArrayBuffer | null;
  unsubscribe(): Promise<boolean>;
}

export interface PushManagerLike {
  getSubscription(): Promise<PushSubscriptionLike | null>;
  subscribe(options: { userVisibleOnly: boolean; applicationServerKey: BufferSource }): Promise<PushSubscriptionLike>;
}

export type FetchLike = (url: string, init?: RequestInit) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

/** La clave VAPID del relay (65 bytes, punto P-256 sin comprimir), o `null` si el relay no tiene pushes. */
export async function fetchVapidKey(fetcher: FetchLike, base = ""): Promise<Uint8Array | null> {
  const response = await fetcher(`${base}/v1/vapid`, { cache: "no-store" });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`vapid: HTTP ${response.status}`);
  const body = (await response.json()) as { publicKey?: unknown };
  if (typeof body.publicKey !== "string") throw new Error("vapid: no key");
  const key = b64urlDecode(body.publicKey);
  if (key.length !== 65 || key[0] !== 0x04) throw new Error("vapid: bad key");
  return key;
}

function sameKey(a: ArrayBuffer | null | undefined, b: Uint8Array): boolean {
  if (!a) return false;
  const x = new Uint8Array(a);
  return x.length === b.length && x.every((v, i) => v === b[i]);
}

/** Una suscripción con la clave VAPID actual (reusa la que hay si es de esa clave, salvo con `renew`: entonces siempre
 *  una nueva, con otro endpoint). */
export async function ensureSubscription(manager: PushManagerLike, vapid: Uint8Array, renew = false): Promise<PushSubscriptionLike> {
  const existing = await manager.getSubscription();
  if (existing) {
    const key = existing.options?.applicationServerKey;
    // Sin `options` (navegadores viejos) no se puede saber: se reusa.
    if (!renew && (key === undefined || sameKey(key, vapid))) return existing;
    await existing.unsubscribe().catch(() => false);
  }
  return manager.subscribe({ userVisibleOnly: true, applicationServerKey: vapid as BufferSource });
}

export function subscriptionKeys(subscription: PushSubscriptionLike): WebPushSubscriptionKeys {
  const p256dh = subscription.getKey("p256dh");
  const auth = subscription.getKey("auth");
  if (!p256dh || !auth) throw new Error("push subscription without keys");
  return { endpoint: subscription.endpoint, p256dh: new Uint8Array(p256dh), auth: new Uint8Array(auth) };
}

export interface SubscribeDeps {
  manager: PushManagerLike;
  fetch: FetchLike;
  register(keys: WebPushSubscriptionKeys): void;
  /** Ver `ensureSubscription`. */
  renew?: boolean;
}

/** Suscribe y registra en el relay. `false` si el relay no tiene pushes. */
export async function subscribePush(deps: SubscribeDeps): Promise<boolean> {
  const vapid = await fetchVapidKey(deps.fetch);
  if (!vapid) return false;
  const subscription = await ensureSubscription(deps.manager, vapid, deps.renew ?? false);
  deps.register(subscriptionKeys(subscription));
  return true;
}

/** Desemparejar: se da de baja la suscripción (el relay ya no puede mandar nada). */
export async function unsubscribePush(manager: PushManagerLike | null): Promise<void> {
  try {
    await (await manager?.getSubscription())?.unsubscribe();
  } catch {
    // Mejor esfuerzo.
  }
}

/** El `pushManager` del service worker de la app, si hay. */
export async function pushManager(): Promise<PushManagerLike | null> {
  if (!("serviceWorker" in navigator) || typeof PushManager === "undefined") return null;
  // Sin service worker registrado (modo dev) `ready` no termina nunca.
  const registration = await Promise.race([
    navigator.serviceWorker.ready,
    new Promise<null>((resolve) => setTimeout(() => resolve(null), 10_000)),
  ]);
  return (registration?.pushManager as unknown as PushManagerLike | undefined) ?? null;
}
