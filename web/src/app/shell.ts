import { batch, effect, signal } from "@preact/signals";
import { b64urlDecode } from "../crypto/b64";
import { createPasskey } from "../presence/webauthn";
import { Cache } from "../store/cache";
import { KeyStore, requestPersistentStorage, type StoredPairing } from "../store/keys";
import { SeenIds } from "../store/seen";
import { startPairing } from "../transport/Pairing";
import type { NotificationPermission } from "../ui/screens/types";
import { ShellUI, type AppContext } from "./context";
import { defaultDeviceName, deviceModel } from "./install";
import { createActivityModel, type ActivityModel } from "./models/activity";
import { createHomeModel, type HomeModel } from "./models/home";
import { createPairingModel, LOST_PAIRING_MESSAGE, revokedMessage, type PairingModel } from "./models/pairing";
import { createSettingsModel, type SettingsModel } from "./models/settings";
import { HOME, parseRoute, Router, type Route } from "./router";
import { APP_VERSION, forget, openSession, registerPush, retire, type Session, type Storage } from "./session";

// El shell de la app instalada: arranca (claves y caché de IndexedDB), arma la sesión con la Mac emparejada o el flujo
// de emparejamiento, maneja la revocación y el desemparejar, el router, los avisos y los mensajes del service worker.

export interface Active {
  session: Session;
  ctx: AppContext;
  home: HomeModel;
  activity: ActivityModel;
  settings: SettingsModel;
}

export interface ShellEnvironment {
  mode: string;
  window: Window;
  /** Solo para los tests: el almacenamiento y la sesión sin IndexedDB ni relay de verdad. */
  openStorage?: () => Promise<Storage>;
  openSession?: typeof openSession;
}

/** El texto si no se pudieron borrar las claves al desemparejar (ni borrando la base entera). */
export const FORGET_FAILED_MESSAGE = "This iPhone couldn’t erase its keys. Close PRBar, open it again and unpair once more.";

function notificationPermission(): NotificationPermission {
  if (typeof Notification === "undefined") return "unsupported";
  return Notification.permission;
}

export class Shell {
  readonly ui = new ShellUI();
  readonly router: Router;
  readonly ready = signal(false);
  /** El arranque falló: se muestra el error con "Try Again" en vez de una pantalla en blanco. */
  readonly bootFailed = signal(false);
  readonly active = signal<Active | null>(null);
  /** El flujo de emparejamiento sobre una sesión (un link nuevo mientras ya está emparejado). */
  readonly pairingOpen = signal(false);
  readonly pairing: PairingModel;
  readonly #env: ShellEnvironment;
  #storage: Storage | null = null;
  #activating: Promise<void> | null = null;

  constructor(env: ShellEnvironment) {
    this.#env = env;
    const { window: w } = env;
    this.router = new Router(w.history, w.location);
    const ua = w.navigator.userAgent;
    const touch = w.navigator.maxTouchPoints ?? 0;
    this.pairing = createPairingModel({
      rpId: w.location.hostname,
      model: deviceModel(ua, touch),
      defaultName: defaultDeviceName(ua, touch),
      createPasskey: (options) => createPasskey(options),
      startPairing: (options) => startPairing(options),
      save: async (outcome, deviceName) => {
        const storage = await this.storage();
        await storage.keys.savePairing({ ...outcome, deviceName, pairedAt: Date.now() });
        await requestPersistentStorage();
      },
      currentMac: () => this.active.value?.session.pairing.mac.macName ?? null,
      notifications: {
        permission: notificationPermission,
        request: async () => (typeof Notification === "undefined" ? "unsupported" : Notification.requestPermission()),
      },
      subscribePush: async () => {
        await this.#activating;
        const active = this.active.value;
        if (active) await registerPush(active.session.transport);
      },
      onPaired: (outcome, deviceName) => {
        this.#activating = this.#replaceSession({ ...outcome, deviceName, pairedAt: Date.now() });
      },
      onDone: () => {
        this.pairingOpen.value = false;
        this.router.replace(HOME);
      },
      allowInsecureRelay: env.mode !== "production",
      pageHost: w.location.host,
      requireSameHost: env.mode === "production",
    });
  }

  async storage(): Promise<Storage> {
    if (this.#storage) return this.#storage;
    if (this.#env.openStorage) {
      this.#storage = await this.#env.openStorage();
      return this.#storage;
    }
    const [keys, cache, seen] = await Promise.all([KeyStore.open(), Cache.open(), SeenIds.open()]);
    this.#storage = { keys, cache, seen };
    return this.#storage;
  }

  async boot(): Promise<void> {
    const w = this.#env.window;
    w.addEventListener("hashchange", () => this.#routeChanged());
    w.addEventListener("popstate", () => this.#routeChanged());
    w.navigator.serviceWorker?.addEventListener("message", (event: MessageEvent) => this.#serviceWorkerMessage(event.data));
    w.setInterval(() => this.active.value?.session.store.tick(), 1000);
    let pairing: StoredPairing | null = null;
    try {
      const storage = await this.storage();
      pairing = await storage.keys.loadPairing();
      if (!pairing && (await storage.keys.hasPairing())) {
        // iOS borró parte de los datos (W.3): lo que queda no sirve.
        await forget(storage);
        this.pairing.setNotice(LOST_PAIRING_MESSAGE);
      }
    } catch (error) {
      console.error("storage", error);
    }
    try {
      if (pairing) await this.#activate(pairing);
    } catch (error) {
      // Un emparejamiento guardado que no abre (o algo que tiró al armar la sesión): nunca una pantalla en blanco.
      console.error("boot", error);
      this.bootFailed.value = true;
    }
    this.ready.value = true;
    try {
      this.#routeChanged();
    } catch (error) {
      console.error("route", error);
    }
  }

  /** Desde la pantalla de error del arranque: borra lo guardado y recarga (vuelve a pair:welcome). */
  async resetAfterBootFailure(): Promise<void> {
    try {
      await forget(await this.storage());
    } catch (error) {
      console.error("reset", error);
    }
    this.#env.window.location.reload();
  }

  /** `renewPush`: recién emparejado, la suscripción de push se rehace (otro endpoint) y se espera. */
  async #activate(pairing: StoredPairing, renewPush = false): Promise<void> {
    const storage = await this.storage();
    const session = await (this.#env.openSession ?? openSession)(pairing, {
      storage, mode: this.#env.mode, onRevoked: (mac) => void this.#revoked(session, mac),
    });
    this.use(session);
    const push = registerPush(session.transport, { renew: renewPush }).catch((error) => console.warn("push", error));
    if (renewPush) await push;
  }

  /** Muestra la app para una sesión abierta (los tests la arman sobre FakeTransport). */
  use(session: Session): void {
    const ctx: AppContext = { store: session.store, runner: session.runner, nav: this.router, ui: this.ui };
    this.router.setMine((id) => session.store.isMine(id));
    this.active.value = {
      session, ctx,
      home: createHomeModel(ctx),
      activity: createActivityModel(ctx),
      settings: createSettingsModel(ctx, { version: `PRBar ${APP_VERSION} (web)`, unpair: () => this.unpair() }),
    };
  }

  /** Recién emparejado: la sesión anterior (otra Mac, o la misma) se cierra con `unpair` (la Mac de antes olvida este
   *  teléfono y el relay borra su suscripción de push) y su caché se borra. La suscripción de push se rehace, así el
   *  endpoint que conocía el emparejamiento anterior deja de servir aunque el `unpair` no haya salido. */
  async #replaceSession(pairing: StoredPairing): Promise<void> {
    const previous = this.active.value;
    if (previous) {
      this.active.value = null;
      await retire(previous.session);
    }
    await this.#activate(pairing, true);
  }

  /** `bye(revoked)` de la Mac: se borra todo y vuelve a pair:welcome con el aviso. */
  async #revoked(session: Session, mac: string): Promise<void> {
    if (this.active.value?.session !== session) return;
    session.transport.stop();
    session.store.detach();
    const forgotten = await this.#forget();
    batch(() => {
      this.active.value = null;
      this.pairingOpen.value = false;
      this.pairing.setNotice(forgotten ? revokedMessage(mac) : FORGET_FAILED_MESSAGE);
    });
    this.router.replace({ kind: "pair" });
  }

  /** "Unpair This Mac": avisa a la Mac, borra todo y vuelve a pair:welcome. */
  async unpair(): Promise<void> {
    const active = this.active.value;
    if (!active) return;
    await retire(active.session);
    const forgotten = await this.#forget();
    batch(() => {
      this.active.value = null;
      this.pairingOpen.value = false;
      this.pairing.setNotice(forgotten ? null : FORGET_FAILED_MESSAGE);
    });
    this.router.replace({ kind: "pair" });
  }

  /** Borra claves y caché. `false` si las claves no se pudieron borrar: el aviso lo dice (no se traga el error). */
  async #forget(): Promise<boolean> {
    try {
      await forget(await this.storage());
      return true;
    } catch (error) {
      console.error("forget", error);
      return false;
    }
  }

  /** Cerrar el flujo de emparejamiento abierto sobre una sesión (Cancel). */
  closePairing(): void {
    if (!this.active.value) return;
    this.pairingOpen.value = false;
    this.router.replace(HOME);
  }

  #routeChanged(): void {
    this.router.sync();
    const route = this.router.route.value;
    if (route.kind !== "pairLink") return;
    // El fragmento del link no se deja en la barra (ni en el historial).
    this.router.replace(this.active.value ? HOME : { kind: "pair" });
    if (this.active.value) this.pairingOpen.value = true;
    this.pairing.openLink(route.link);
  }

  #serviceWorkerMessage(data: unknown): void {
    const message = data as { type?: unknown; hash?: unknown } | null;
    if (message?.type === "prbar:navigate" && typeof message.hash === "string") {
      const route: Route = parseRoute(message.hash, this.#env.window.location.origin);
      if (route.kind !== "pairLink") this.router.go(route);
    } else if (message?.type === "prbar:pushsubscriptionchange") {
      const active = this.active.value;
      if (active) void registerPush(active.session.transport).catch(() => {});
    }
  }

  /** Solo fuera de producción: lo que miran las pruebas e2e (`window.__prbar` y `data-*` en `<html>`). */
  exposeTestHooks(): void {
    const root = this.#env.window.document.documentElement;
    const state = () => {
      const active = this.active.value;
      return {
        ready: this.ready.value,
        route: this.router.route.value,
        pairing: this.pairing.step.value.kind,
        sas: this.pairing.step.value.kind === "sas" ? this.pairing.step.value.code : null,
        notice: this.pairing.notice.value,
        link: active?.session.store.link.value.kind ?? "unpaired",
        macName: active?.session.store.macName.value ?? null,
        prs: active?.session.store.home.value?.prs.map((p) => p.id) ?? [],
        alerts: this.ui.alerts.value.map((a) => a.message),
      };
    };
    // Una suscripción de Web Push con claves de la prueba (la del navegador no anda sin red): el relay en modo test la
    // acepta si el endpoint es el de su servicio de push falso.
    const registerWebPush = (sub: { endpoint: string; p256dh: string; auth: string }) => {
      this.active.value?.session.transport.registerWebPush({
        endpoint: sub.endpoint, p256dh: b64urlDecode(sub.p256dh), auth: b64urlDecode(sub.auth),
      });
    };
    (this.#env.window as unknown as { __prbar: unknown }).__prbar = { state, shell: this, registerWebPush };
    effect(() => {
      const s = state();
      root.dataset["ready"] = String(s.ready);
      root.dataset["pairing"] = s.pairing;
      root.dataset["link"] = s.link;
    });
  }
}
