import type { PushKeys } from "../store/keys";
import { GENERIC_PUSH, openPush, type PushNotification } from "./open";

// Lo que hace el service worker con un push y con el toque en la notificación (spec W.6), con las dependencias
// inyectadas para probarlo sin service worker. Regla de iOS: cada push muestra una notificación, pase lo que pase.

export interface PushDeps {
  pushKeys(): Promise<PushKeys | null>;
  seenIds(): Promise<string[]>;
  markSeen(id: string): Promise<void>;
  showNotification(title: string, options: NotificationOptions): Promise<void>;
  setBadge?: ((count: number) => Promise<void>) | undefined;
  now(): number;
}

export const NOTIFICATION_ICON = "/icons/icon-192.png";

/** Abre el push, muestra la notificación, anota el id y pone el número del ícono. Nunca tira. */
export async function handlePush(payload: string | null, deps: PushDeps): Promise<PushNotification> {
  let notification: PushNotification = { ...GENERIC_PUSH };
  try {
    if (payload !== null) {
      const [keys, seen] = await Promise.all([deps.pushKeys().catch(() => null), deps.seenIds().catch((): string[] => [])]);
      notification = openPush(payload, keys, deps.now(), { has: (id) => seen.includes(id) });
    }
  } catch {
    notification = { ...GENERIC_PUSH };
  }
  try {
    await deps.showNotification(notification.title, {
      body: notification.body,
      tag: notification.tag,
      data: { deepLink: notification.deepLink },
      icon: NOTIFICATION_ICON,
      badge: NOTIFICATION_ICON,
    });
  } catch {
    // Sin permiso no hay nada más que hacer.
  }
  if (notification.id) await deps.markSeen(notification.id).catch(() => {});
  if (notification.badge !== undefined) await deps.setBadge?.(notification.badge).catch(() => {});
  return notification;
}

export interface WindowClientLike {
  readonly url: string;
  focus(): Promise<unknown>;
  postMessage(message: unknown): void;
}

export interface ClientsLike {
  matchAll(options: { type: "window"; includeUncontrolled: boolean }): Promise<readonly WindowClientLike[]>;
  openWindow(url: string): Promise<unknown>;
}

/** El mensaje que el service worker le manda a la app para navegar (sin recargar). */
export interface NavigateMessage {
  type: "prbar:navigate";
  hash: string;
}

/** Solo rutas de la app (`#/…`); cualquier otra cosa abre Home. */
export function safeHash(deepLink: unknown): string {
  return typeof deepLink === "string" && /^#\/[A-Za-z0-9/_.%-]*$/.test(deepLink) ? deepLink : GENERIC_PUSH.deepLink;
}

/** Toque en la notificación: enfoca la ventana abierta (y la lleva al link) o abre una nueva ahí. */
export async function openFromNotification(deepLink: unknown, clients: ClientsLike, origin: string): Promise<void> {
  const hash = safeHash(deepLink);
  const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
  const mine = windows.find((w) => w.url.startsWith(origin));
  if (mine) {
    const message: NavigateMessage = { type: "prbar:navigate", hash };
    mine.postMessage(message);
    await mine.focus().catch(() => {});
    return;
  }
  await clients.openWindow(`${origin}/${hash}`);
}
