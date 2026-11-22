// La app solo funciona instalada en la pantalla de inicio (spec W.1/W.4): en Safari (sin instalar) se muestra la
// pantalla `install` y nunca se generan claves. iOS guarda aparte los datos de Safari y los de la app instalada.

export interface InstallEnvironment {
  matchMedia?: ((query: string) => { matches: boolean }) | undefined;
  navigator?: { standalone?: boolean; userAgent?: string; maxTouchPoints?: number } | undefined;
  location?: { search: string } | undefined;
  /** `import.meta.env.MODE`. */
  mode: string;
}

/** `true` si la página corre como app instalada. Solo en builds que no son de producción, `?standalone=1` lo fuerza
 *  (lo usan las pruebas e2e). */
export function isStandalone(env: InstallEnvironment): boolean {
  if (env.matchMedia?.("(display-mode: standalone)").matches) return true;
  if (env.navigator?.standalone === true) return true;
  if (env.mode !== "production" && env.location) {
    return new URLSearchParams(env.location.search).get("standalone") === "1";
  }
  return false;
}

export type Platform = "ios" | "android" | "other";

function isIOS(userAgent: string, maxTouchPoints: number): boolean {
  // iPadOS se presenta como Mac; se distingue por la pantalla táctil.
  return /iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1);
}

export function platformOf(userAgent: string, maxTouchPoints = 0): Platform {
  if (isIOS(userAgent, maxTouchPoints)) return "ios";
  if (/Android/.test(userAgent)) return "android";
  return "other";
}

/** El `model` que se le dice a la Mac al emparejar (W.4.5): lo que se pueda saber del user agent. */
export function deviceModel(userAgent: string, maxTouchPoints = 0): string {
  if (/iPhone|iPod/.test(userAgent)) return "iPhone";
  if (/Android/.test(userAgent)) return "Android";
  if (/iPad/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1)) return "Device";
  if (/Macintosh|Mac OS X/.test(userAgent)) return "Mac";
  return "Device";
}

/** El nombre por defecto del campo "Device name". */
export function defaultDeviceName(userAgent: string, maxTouchPoints = 0): string {
  const model = deviceModel(userAgent, maxTouchPoints);
  return model === "Device" ? "iPhone" : model;
}

/** El evento `beforeinstallprompt` de Chrome/Android (no está en los tipos del DOM). */
export interface InstallPromptEvent extends Event {
  prompt(): Promise<unknown>;
}
