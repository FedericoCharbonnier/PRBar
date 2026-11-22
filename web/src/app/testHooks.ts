import { effect } from "@preact/signals";
import { b64urlDecode } from "../crypto/b64";
import type { Shell } from "./shell";

// Solo fuera de producción: lo que miran las pruebas e2e (`window.__prbar` y `data-*` en `<html>`). main.tsx lo importa
// con `import()` detrás de `MODE !== "production"`, así el build de producción no lo incluye.

export function exposeTestHooks(shell: Shell, w: Window): void {
  const root = w.document.documentElement;
  const state = () => {
    const active = shell.active.value;
    return {
      ready: shell.ready.value,
      route: shell.router.route.value,
      pairing: shell.pairing.step.value.kind,
      sas: shell.pairing.step.value.kind === "sas" ? shell.pairing.step.value.code : null,
      notice: shell.pairing.notice.value,
      link: active?.session.store.link.value.kind ?? "unpaired",
      macName: active?.session.store.macName.value ?? null,
      prs: active?.session.store.home.value?.prs.map((p) => p.id) ?? [],
      alerts: shell.ui.alerts.value.map((a) => a.message),
    };
  };
  // Una suscripción de Web Push con claves de la prueba (la del navegador no anda sin red): el relay en modo test la
  // acepta si el endpoint es el de su servicio de push falso.
  const registerWebPush = (sub: { endpoint: string; p256dh: string; auth: string }) => {
    shell.active.value?.session.transport.registerWebPush({
      endpoint: sub.endpoint, p256dh: b64urlDecode(sub.p256dh), auth: b64urlDecode(sub.auth),
    });
  };
  (w as unknown as { __prbar: unknown }).__prbar = { state, shell, registerWebPush };
  effect(() => {
    const s = state();
    root.dataset["ready"] = String(s.ready);
    root.dataset["pairing"] = s.pairing;
    root.dataset["link"] = s.link;
  });
}
