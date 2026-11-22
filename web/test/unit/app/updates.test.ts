import { describe, expect, it } from "vitest";
import { AppUpdater, UPDATE_CHECK_MS, type RegistrationLike } from "../../../src/app/updates";

/** Un `navigator.serviceWorker` de mentira: el que espera toma el control al recibir `prbar:activate`. */
function setup(options: { waiting?: boolean; controller?: boolean } = {}) {
  const log: string[] = [];
  let now = 0;
  let foreground: () => void = () => {};
  const controllerChange: (() => void)[] = [];
  const worker = { postMessage: (m: unknown) => {
    log.push(`post ${(m as { type: string }).type}`);
    for (const listener of controllerChange.splice(0)) listener();
  } };
  const registration: RegistrationLike & { waiting: typeof worker | null } = {
    waiting: options.waiting ? worker : null,
    update: async () => void log.push("update"),
  };
  const updater = new AppUpdater({
    container: {
      controller: options.controller === false ? null : {},
      register: async () => registration,
      addEventListener: (_type, listener) => void controllerChange.push(listener),
    },
    now: () => now,
    setTimeout: () => null,
    reload: () => void log.push("reload"),
    onForeground: (listener) => (foreground = listener),
  });
  return {
    updater, registration, worker, log,
    advance: (ms: number) => (now += ms),
    foreground: async () => {
      foreground();
      await new Promise((r) => setTimeout(r, 0));
    },
  };
}

describe("AppUpdater (versiones nuevas)", () => {
  it("al arrancar, una versión que espera se activa enseguida y recarga", async () => {
    const t = setup({ waiting: true });
    expect(await t.updater.start()).toBe(true);
    expect(t.log).toEqual(["post prbar:activate", "reload"]);
  });

  it("la primera instalación (sin controller) no recarga", async () => {
    const t = setup({ waiting: true, controller: false });
    expect(await t.updater.start()).toBe(false);
    expect(t.log).toEqual([]);
  });

  it("al volver al primer plano busca otra versión, como mucho cada 30 min", async () => {
    const t = setup();
    await t.updater.start();
    await t.foreground();
    expect(t.log).toEqual([]);
    t.advance(UPDATE_CHECK_MS);
    await t.foreground();
    expect(t.log).toEqual(["update"]);
    t.advance(60_000);
    await t.foreground();
    expect(t.log).toEqual(["update"]);
  });

  it("una versión que llegó con la app abierta se aplica al volver, solo en un punto seguro", async () => {
    const t = setup();
    await t.updater.start();
    let safe = false;
    t.updater.isSafe = () => safe;
    t.registration.waiting = t.worker;
    await t.foreground();
    expect(t.log).not.toContain("reload");
    safe = true;
    await t.foreground();
    expect(t.log).toEqual(["post prbar:activate", "reload"]);
  });
});
