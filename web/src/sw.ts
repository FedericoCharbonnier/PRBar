/// <reference lib="webworker" />
// Service worker (spec W.1 y W.6). Por ahora solo se instala y toma control; la precarga del shell y los
// manejadores de `push` y `notificationclick` llegan en C6. Se compila aparte como `/sw.js` (sin hash).

declare const self: ServiceWorkerGlobalScope;

self.addEventListener("install", () => {
  // La versión nueva espera al próximo arranque (W.1): no se llama `skipWaiting`.
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

export {};
