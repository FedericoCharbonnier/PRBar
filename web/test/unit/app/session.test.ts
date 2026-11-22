import { describe, expect, it } from "vitest";
import { forget, retire, type Session, type Storage } from "../../../src/app/session";
import { makeApp } from "./helpers";

describe("retire (desemparejar o reemplazar la sesión)", () => {
  function session() {
    const app = makeApp();
    const calls: string[] = [];
    const unpair = app.transport.unpair.bind(app.transport);
    app.transport.unpair = async () => {
      calls.push("unpair");
      await unpair();
    };
    const stop = app.transport.stop.bind(app.transport);
    app.transport.stop = () => {
      calls.push("stop");
      stop();
    };
    const s = { pairing: null, transport: app.transport, store: app.store, runner: app.runner } as unknown as Session;
    return { app, calls, s };
  }

  it("avisa a la Mac con unpair antes de cortar, y borra el store", async () => {
    const { app, calls, s } = session();
    expect(app.store.home.value).not.toBeNull();
    await retire(s);
    expect(calls).toEqual(["unpair", "stop"]);
    expect(app.store.home.value).toBeNull();
  });

  it("si el unpair falla (sin sesión con la Mac) igual corta y borra", async () => {
    const { app, calls, s } = session();
    app.transport.unpair = async () => {
      calls.push("unpair");
      throw new Error("offline");
    };
    await retire(s);
    expect(calls).toEqual(["unpair", "stop"]);
    expect(app.store.home.value).toBeNull();
  });
});

describe("forget", () => {
  function storage(keysFail: boolean) {
    const calls: string[] = [];
    const store = (name: string, fail = false) => ({
      clear: async () => {
        calls.push(`clear ${name}`);
        if (fail) throw new DOMException("Connection to Indexed Database server lost", "UnknownError");
      },
      close: () => calls.push(`close ${name}`),
    });
    const s = { keys: store("keys", keysFail), cache: store("cache"), seen: store("seen") } as unknown as Storage;
    return { s, calls };
  }

  it("borra claves, caché e ids vistos", async () => {
    const { s, calls } = storage(false);
    let wiped = false;
    await forget(s, async () => void (wiped = true));
    expect(calls).toEqual(["clear keys", "clear cache", "clear seen"]);
    expect(wiped).toBe(false);
  });

  it("si las claves no se borran, borra la base entera; si tampoco, tira (no se lo traga)", async () => {
    const { s, calls } = storage(true);
    let wiped = false;
    await forget(s, async () => void (wiped = true));
    expect(wiped).toBe(true);
    expect(calls).toContain("close keys");
    await expect(forget(s, async () => { throw new Error("blocked"); })).rejects.toThrow("blocked");
  });
});
