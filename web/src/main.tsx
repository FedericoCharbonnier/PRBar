import { render } from "preact";
import { isStandalone, platformOf, type InstallPromptEvent } from "./app/install";
import { Shell } from "./app/shell";
import { AppUpdater, type ContainerLike } from "./app/updates";
import { App, InstallGate } from "./ui/app";
import { BootError } from "./ui/screens";
import { installPressFeedback } from "./ui/motion/press";
import { installKeyboardTracking } from "./ui/viewport";
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

/** Registra el service worker (updates.ts): una versión nueva que quedó esperando se activa ahora, al arrancar, antes
 *  de mostrar nada, o después al volver al primer plano en un punto seguro. Devuelve `true` si la página se va a
 *  recargar. */
const updater = "serviceWorker" in navigator && MODE !== "development" ? new AppUpdater({
  container: navigator.serviceWorker as unknown as ContainerLike,
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  reload: () => location.reload(),
  onForeground: (listener) => {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") listener();
    });
  },
}) : null;

async function serviceWorker(): Promise<boolean> {
  try {
    return (await updater?.start()) ?? false;
  } catch (error) {
    console.warn("service worker", error);
    return false;
  }
}

async function start(): Promise<void> {
  const root = document.getElementById("app");
  if (!root) return;
  const standalone = isStandalone({
    matchMedia: (query) => matchMedia(query), navigator: navigator as Navigator & { standalone?: boolean }, location, mode: MODE,
  });
  if (await serviceWorker()) return;
  installPressFeedback();
  if (!standalone) {
    render(<InstallGate platform={platformOf(navigator.userAgent, navigator.maxTouchPoints)} prompt={() => installPrompt} />, root);
    return;
  }
  installKeyboardTracking();
  const shell = new Shell({ mode: MODE, window });
  if (updater) updater.isSafe = () => shell.isSafeToReload();
  if (MODE !== "production") shell.exposeTestHooks();
  render(<App shell={shell} />, root);
  await shell.boot();
}

start().catch((error: unknown) => {
  // Algo tiró antes de armar la app: el error con "Try Again" en vez de una pantalla en blanco.
  console.error("start", error);
  const root = document.getElementById("app");
  if (root) render(<BootError onRetry={() => location.reload()} />, root);
});
