import { ActionRunner } from "./actions";
import { AppStore } from "./store";
import { passkeyAuthorizer } from "../presence/webauthn";
import { pushManager, subscribePush, unsubscribePush } from "../push/subscribe";
import type { Cache } from "../store/cache";
import type { KeyStore, StoredPairing } from "../store/keys";
import type { SeenIds } from "../store/seen";
import { LiveTransport, type Transport } from "../transport/Transport";

// Lo que vive mientras el teléfono está emparejado: el transporte con la Mac, el store y el que manda comandos. Se
// arma con lo guardado al arrancar (o recién emparejado) y se tira al desemparejar o con un `bye(revoked)`.

export const APP_VERSION = "0.1.0";

export interface Storage {
  keys: KeyStore;
  cache: Cache;
  seen: SeenIds;
}

export interface Session {
  pairing: StoredPairing;
  transport: Transport;
  store: AppStore;
  runner: ActionRunner;
}

/** Un relay local de las pruebas (IP literal o `localhost`): solo fuera de producción, por `ws://`. */
export function isLocalRelay(host: string): boolean {
  const name = host.replace(/:\d+$/, "");
  return name === "localhost" || /^\d+\.\d+\.\d+\.\d+$/.test(name);
}

export interface SessionOptions {
  storage: Storage;
  /** `import.meta.env.MODE`. */
  mode: string;
  onRevoked(macName: string): void;
}

export async function openSession(pairing: StoredPairing, options: SessionOptions): Promise<Session> {
  const mailboxRevisions = await options.storage.cache.loadMailboxRevisions().catch(() => ({}));
  const transport = new LiveTransport({
    paired: pairing.mac,
    keys: pairing.keys,
    appVersion: `web-${APP_VERSION}`,
    deviceName: pairing.deviceName,
    mailboxRevisions,
    insecure: options.mode !== "production" && isLocalRelay(pairing.mac.relayHost),
  });
  const store = new AppStore({
    transport,
    cache: options.storage.cache,
    onRevoked: () => options.onRevoked(store.macName.value ?? pairing.mac.macName),
    setBadge: (count) => setAppBadge(count),
  });
  store.macName.value = pairing.mac.macName;
  await store.loadCache();
  const authorize = pairing.presence ? passkeyAuthorizer(pairing.presence) : null;
  const runner = new ActionRunner(() => transport, () => authorize);
  store.attach();
  transport.start();
  return { pairing, transport, store, runner };
}

export function setAppBadge(count: number): void {
  const nav = navigator as Navigator & { setAppBadge?: (n: number) => Promise<void>; clearAppBadge?: () => Promise<void> };
  try {
    void (count > 0 ? nav.setAppBadge?.(count) : nav.clearAppBadge?.())?.catch(() => {});
  } catch {
    // Sin la API de insignias.
  }
}

/** Suscribe Web Push y lo registra en el relay (si hay permiso y service worker). */
export interface RegisterPushOptions {
  /** Recién emparejado con otra Mac (o de nuevo): la suscripción de antes se da de baja y se hace otra, así su
   *  endpoint (que el relay tenía para el emparejamiento anterior) deja de servir. */
  renew?: boolean;
}

export async function registerPush(transport: Transport, options: RegisterPushOptions = {}): Promise<boolean> {
  const granted = typeof Notification !== "undefined" && Notification.permission === "granted";
  if (!granted && !options.renew) return false;
  const manager = await pushManager();
  if (!manager) return false;
  if (!granted) {
    await unsubscribePush(manager);
    return false;
  }
  return subscribePush({
    manager,
    fetch: (url, init) => fetch(url, init),
    register: (keys) => transport.registerWebPush(keys),
    renew: options.renew ?? false,
  });
}

/** Cierra una sesión que se deja (desemparejar, o un emparejamiento nuevo que la reemplaza): avisa a la Mac con
 *  `unpair` (mejor esfuerzo: sin sesión abierta no sale), así la Mac olvida este teléfono y el relay borra su buzón y su
 *  suscripción de push; después corta el transporte y borra el store en memoria. */
export async function retire(session: Session): Promise<void> {
  await session.transport.unpair().catch(() => {});
  session.transport.stop();
  session.store.detach();
  session.store.wipe();
}

/** Revocado o desemparejado: claves, caché, ids vistos, suscripción de push e insignia. */
export async function forget(storage: Storage): Promise<void> {
  // La baja de la suscripción no se espera (sin service worker tardaría en rendirse).
  void pushManager().then(unsubscribePush).catch(() => {});
  await Promise.all([
    storage.keys.clear().catch(() => {}),
    storage.cache.clear().catch(() => {}),
    storage.seen.clear().catch(() => {}),
  ]);
  setAppBadge(0);
}
