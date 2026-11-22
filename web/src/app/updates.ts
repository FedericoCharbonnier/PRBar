// Las versiones nuevas de la app (revisión M2). El service worker nuevo se instala solo y queda esperando (sw.ts, sin
// `skipWaiting`); acá se decide cuándo pasar a él: al arrancar, o al volver al primer plano si la app está en un punto
// seguro (una pestaña raíz, sin hojas abiertas ni comandos en curso). Nunca se recarga en medio de una acción (W.1).
// iOS mantiene viva la app instalada durante días, así que al volver al primer plano también se busca una versión
// nueva (`registration.update()`, como mucho cada 30 min): la próxima vez que se vuelva, se aplica.

/** Lo que se usa de `ServiceWorkerRegistration`. */
export interface RegistrationLike {
  readonly waiting: { postMessage(message: unknown): void } | null;
  update(): Promise<unknown>;
}

/** Lo que se usa de `navigator.serviceWorker`. */
export interface ContainerLike {
  readonly controller: unknown;
  register(url: string, options: { scope: string }): Promise<RegistrationLike>;
  addEventListener(type: "controllerchange", listener: () => void, options?: { once: boolean }): void;
}

export interface UpdaterEnvironment {
  container: ContainerLike;
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  reload(): void;
  /** Avisa cuando la página vuelve a estar visible. */
  onForeground(listener: () => void): void;
}

/** Cada cuánto, como mucho, se pregunta al servidor si hay una versión nueva. */
export const UPDATE_CHECK_MS = 30 * 60_000;

export class AppUpdater {
  readonly #env: UpdaterEnvironment;
  #registration: RegistrationLike | null = null;
  #lastCheck = 0;
  #applying = false;
  /** Si la app está en un punto seguro para recargar. Lo pone el shell cuando arma la app. */
  isSafe: () => boolean = () => false;

  constructor(env: UpdaterEnvironment) {
    this.#env = env;
  }

  /** Registra el service worker. Si una versión nueva quedó esperando, la activa ya (al arrancar no hay nada en curso)
   *  y devuelve `true`: la página se va a recargar. */
  async start(): Promise<boolean> {
    const registration = await this.#env.container.register("/sw.js", { scope: "/" });
    this.#registration = registration;
    this.#lastCheck = this.#env.now();
    this.#env.onForeground(() => void this.foreground());
    if (registration.waiting && this.#env.container.controller) {
      await this.#apply();
      return true;
    }
    return false;
  }

  /** La app volvió al primer plano: aplica una versión que espera (si es un buen momento) y busca otra. */
  async foreground(): Promise<void> {
    const registration = this.#registration;
    if (!registration || this.#applying) return;
    if (registration.waiting && this.#env.container.controller && this.isSafe()) {
      await this.#apply();
      return;
    }
    if (this.#env.now() - this.#lastCheck < UPDATE_CHECK_MS) return;
    this.#lastCheck = this.#env.now();
    try {
      await registration.update();
    } catch {
      // Sin red: se prueba la próxima vez.
    }
  }

  /** Le dice al que espera que tome el control y recarga cuando lo hizo (o a los 3 s). */
  async #apply(): Promise<void> {
    const waiting = this.#registration?.waiting;
    if (!waiting) return;
    this.#applying = true;
    await new Promise<void>((resolve) => {
      this.#env.container.addEventListener("controllerchange", () => resolve(), { once: true });
      this.#env.setTimeout(resolve, 3000);
      waiting.postMessage({ type: "prbar:activate" });
    });
    this.#env.reload();
  }
}
