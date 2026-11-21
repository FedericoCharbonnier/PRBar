/// <reference lib="webworker" />
import { handlePush, openFromNotification } from "./push/handler";
import { fetchVapidKey } from "./push/subscribe";
import { KeyStore } from "./store/keys";
import { SeenIds } from "./store/seen";
import { fetchVerified, type PrecacheManifest } from "./sw/precache";

// Service worker (spec W.1 y W.6). Se compila aparte como `/sw.js` (IIFE, sin hash, se revalida siempre).
// - Precarga el shell (la lista y el SHA-256 de cada archivo los pone el build en `__PRBAR_PRECACHE__`) para abrir sin
//   red. Cada archivo se baja saltando la caché HTTP y se verifica contra su hash antes de guardarlo; si alguno no
//   coincide, la instalación falla (sw/precache.ts). `index.html` sale de la caché de esta versión, así la página y el
//   service worker van juntos.
// - Una versión nueva queda esperando: la app la activa al próximo arranque (`prbar:activate`), nunca en medio de algo.
// - `push`: abre el sobre con `devicePushKey` y siempre muestra una notificación; `notificationclick`: enfoca o abre la
//   app y la lleva al link.

declare const self: ServiceWorkerGlobalScope;
declare const __PRBAR_PRECACHE__: PrecacheManifest;
declare const __PRBAR_CACHE__: string;

const PRECACHE: PrecacheManifest = typeof __PRBAR_PRECACHE__ === "undefined" ? {} : __PRBAR_PRECACHE__;
const CACHE = typeof __PRBAR_CACHE__ === "undefined" ? "prbar-dev" : __PRBAR_CACHE__;

self.addEventListener("install", (event) => {
  // Sin `skipWaiting`: la versión nueva espera al próximo arranque (W.1).
  // Primero se verifica todo y recién después se abre la caché: nada sin verificar llega a guardarse.
  event.waitUntil((async () => {
    const verified = await fetchVerified(PRECACHE, (path, init) => fetch(path, init));
    const cache = await caches.open(CACHE);
    for (const [path, response] of verified) await cache.put(path, response);
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith("prbar-") && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

self.addEventListener("message", (event) => {
  // La app, al arrancar, pide activar una versión que estaba esperando (todavía no hay nada en curso).
  if ((event.data as { type?: unknown } | null)?.type === "prbar:activate") void self.skipWaiting();
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === "navigate") {
    event.respondWith((async () => {
      const cached = await caches.match("/index.html", { cacheName: CACHE });
      if (cached) return cached;
      return fetch(request);
    })());
    return;
  }
  if (!Object.hasOwn(PRECACHE, url.pathname)) return;
  event.respondWith((async () => (await caches.match(url.pathname, { cacheName: CACHE })) ?? fetch(request))());
});

async function openStores(): Promise<{ keys: KeyStore | null; seen: SeenIds | null }> {
  const [keys, seen] = await Promise.all([KeyStore.open().catch(() => null), SeenIds.open().catch(() => null)]);
  return { keys, seen };
}

self.addEventListener("push", (event) => {
  event.waitUntil((async () => {
    let text: string | null = null;
    try {
      text = event.data?.text() ?? null;
    } catch {
      text = null;
    }
    const { keys, seen } = await openStores();
    try {
      await handlePush(text, {
        pushKeys: async () => (await keys?.pushKeys()) ?? null,
        seenIds: async () => (await seen?.list()) ?? [],
        markSeen: async (id) => seen?.add(id),
        showNotification: (title, options) => self.registration.showNotification(title, options),
        setBadge: async (count) => {
          const nav = self.navigator as Navigator & { setAppBadge?: (n: number) => Promise<void>; clearAppBadge?: () => Promise<void> };
          if (count > 0) await nav.setAppBadge?.(count);
          else await nav.clearAppBadge?.();
        },
        now: () => Date.now(),
      });
    } finally {
      keys?.close();
      seen?.close();
    }
  })());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const deepLink = (event.notification.data as { deepLink?: unknown } | null)?.deepLink;
  event.waitUntil(openFromNotification(deepLink, self.clients, self.location.origin));
});

self.addEventListener("pushsubscriptionchange", (event) => {
  // Mejor esfuerzo: otra suscripción con la clave VAPID actual. El relay la recibe la próxima vez que la app se
  // conecta (la app vuelve a registrar la suscripción en cada arranque); si hay una ventana abierta, se le avisa ya.
  const change = event as Event & { waitUntil(p: Promise<unknown>): void };
  change.waitUntil((async () => {
    try {
      const vapid = await fetchVapidKey((url, init) => fetch(url, init));
      if (vapid) await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: vapid as BufferSource });
    } catch {
      // Se rehace al próximo arranque.
    }
    for (const client of await self.clients.matchAll({ type: "window", includeUncontrolled: true })) {
      client.postMessage({ type: "prbar:pushsubscriptionchange" });
    }
  })());
});
