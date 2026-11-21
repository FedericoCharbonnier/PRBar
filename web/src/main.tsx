import { render } from "preact";
import { isStandalone, platformOf, type InstallPromptEvent } from "./app/install";
import { Shell } from "./app/shell";
import { App, InstallGate } from "./ui/app";
import "./ui/tokens.css";
import "./ui/base.css";

// Punto de entrada. Fuera de la pantalla de inicio solo se muestra `install` (nunca se generan claves ahí, W.1).

const MODE = import.meta.env.MODE;

// `beforeinstallprompt` puede llegar antes de montar la pantalla.
let installPrompt: InstallPromptEvent | null = null;
addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  installPrompt = event as InstallPromptEvent;
});

/** Registra el service worker. Si una versión nueva quedó esperando, se activa ahora, al arrancar, antes de mostrar
 *  nada: nunca se recarga en medio de una acción (W.1). Devuelve `true` si la página se va a recargar. */
async function serviceWorker(): Promise<boolean> {
  if (!("serviceWorker" in navigator) || MODE === "development") return false;
  try {
    const registration = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
    if (registration.waiting && navigator.serviceWorker.controller) {
      const changed = new Promise<void>((resolve) => {
        navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true });
        setTimeout(resolve, 3000);
      });
      registration.waiting.postMessage({ type: "prbar:activate" });
      await changed;
      location.reload();
      return true;
    }
  } catch (error) {
    console.warn("service worker", error);
  }
  return false;
}

async function start(): Promise<void> {
  const root = document.getElementById("app");
  if (!root) return;
  const standalone = isStandalone({
    matchMedia: (query) => matchMedia(query), navigator: navigator as Navigator & { standalone?: boolean }, location, mode: MODE,
  });
  if (await serviceWorker()) return;
  if (!standalone) {
    render(<InstallGate platform={platformOf(navigator.userAgent, navigator.maxTouchPoints)} prompt={() => installPrompt} />, root);
    return;
  }
  const shell = new Shell({ mode: MODE, window });
  if (MODE !== "production") shell.exposeTestHooks();
  render(<App shell={shell} />, root);
  await shell.boot();
}

void start();
