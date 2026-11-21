import { describe, expect, it } from "vitest";
import { retire, type Session } from "../../../src/app/session";
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
