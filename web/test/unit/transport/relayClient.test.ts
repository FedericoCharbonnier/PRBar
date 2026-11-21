import { describe, expect, it } from "vitest";
import { generateEd25519, ed25519PublicKey } from "../../../src/crypto/curves";
import {
  PONG_TIMEOUT_MS, RelayClient, RelayClosedError, RelayLink, RESUME_CHECK_MS, type RelayState,
} from "../../../src/transport/RelayClient";
import { FakeRelay, FakeVisibility, flush, ManualClock } from "./harness";

const account = "hohrh3jbgktkby7euvoae3wjze";
const device = "fmh7nna7zna2bylvvuaupg6fnm";

function setup() {
  const relay = new FakeRelay();
  const key = generateEd25519();
  relay.devices.push({ account, device, relayKey: ed25519PublicKey(key) });
  const clock = new ManualClock();
  const visibility = new FakeVisibility();
  const client = new RelayClient({
    host: relay.host, credential: { kind: "signed", account, client: device, key }, webSocket: relay.factory, clock,
    visibility, random: () => 0.5,
  });
  const states: RelayState[] = [];
  client.subscribe((state) => states.push(state));
  return { relay, key, clock, visibility, client, states };
}

describe("RelayLink", () => {
  it("se autentica con la firma del desafío y entrega los marcos", async () => {
    const { relay, key, clock } = setup();
    const link = new RelayLink({ host: relay.host, credential: { kind: "signed", account, client: device, key },
                                 webSocket: relay.factory, clock });
    const ready = await link.connect();
    expect(ready).toEqual({ mac: "online", since: relay.macSince });
    expect(relay.last.url).toBe("wss://prbar.example.org/v1/ws");
    expect(relay.last.protocols).toEqual(["prbar-relay.v1"]);
    const received: string[] = [];
    link.onMessage = (m) => received.push(m.t);
    relay.last.deliver({ t: "presence", mac: "offline", since: 2 });
    await flush();
    expect(received).toEqual(["presence"]);
  });

  it("una firma con otra clave: el relay cierra con 4401", async () => {
    const { relay, clock } = setup();
    const link = new RelayLink({ host: relay.host, webSocket: relay.factory, clock,
                                 credential: { kind: "signed", account, client: device, key: generateEd25519() } });
    await expect(link.connect()).rejects.toMatchObject({ code: 4401 });
  });

  it("firma el host sin puerto", async () => {
    const { relay, key, clock } = setup();
    const link = new RelayLink({ host: `${relay.host}:8443`, credential: { kind: "signed", account, client: device, key },
                                 webSocket: relay.factory, clock });
    await link.connect();
    expect(relay.last.url).toBe("wss://prbar.example.org:8443/v1/ws");
  });

  it("host inválido o IP sin modo inseguro", async () => {
    const { relay, key, clock } = setup();
    for (const host of ["127.0.0.1:8080", "evil.org/x"]) {
      const link = new RelayLink({ host, credential: { kind: "signed", account, client: device, key },
                                   webSocket: relay.factory, clock });
      await expect(link.connect()).rejects.toBeInstanceOf(RelayClosedError);
    }
  });

  it("sin desafío a tiempo falla", async () => {
    const { relay, key, clock } = setup();
    relay.answers = false;
    const link = new RelayLink({ host: relay.host, credential: { kind: "signed", account, client: device, key },
                                 webSocket: relay.factory, clock });
    const result = link.connect().catch((e: unknown) => e);
    await clock.advance(15_000);
    expect(await result).toBeInstanceOf(RelayClosedError);
  });

  it("manda ping cada 20 s y un marco ilegible corta", async () => {
    const { relay, key, clock } = setup();
    const link = new RelayLink({ host: relay.host, credential: { kind: "signed", account, client: device, key },
                                 webSocket: relay.factory, clock });
    await link.connect();
    await clock.advance(40_000);
    expect(relay.last.sent.filter((m) => m.t === "ping").length).toBe(2);
    let closed: RelayClosedError | null = null;
    link.onClose = (e) => (closed = e);
    relay.last.deliver("not json");
    await flush();
    expect(closed).toBeInstanceOf(RelayClosedError);
    expect(link.isOpen).toBe(false);
  });
});

describe("RelayClient", () => {
  it("conecta, sigue la presencia de la Mac y reconecta con backoff", async () => {
    const { relay, clock, client, states } = setup();
    client.start();
    await flush();
    expect(client.state).toEqual({ kind: "ready", mac: "online", since: relay.macSince });
    relay.setMac(false);
    await flush();
    expect(client.state).toMatchObject({ kind: "ready", mac: "offline" });

    relay.last.drop(1006);
    await flush();
    expect(client.state).toMatchObject({ kind: "unreachable", retryAt: clock.now() + 1000 });
    // El relay sigue caído: 1 s, 2 s, 4 s…
    relay.answers = false;
    await clock.advance(1000);
    expect(client.state.kind).toBe("connecting");
    await clock.advance(15_000);
    expect(client.state).toMatchObject({ kind: "unreachable", retryAt: clock.now() + 2000 });
    relay.answers = true;
    await clock.advance(2000);
    expect(client.state.kind).toBe("ready");
    expect(states.map((s) => s.kind)).toContain("connecting");
  });

  it("el backoff llega a 30 s y tiene jitter", async () => {
    const relay = new FakeRelay();
    relay.answers = false;
    const clock = new ManualClock();
    const client = new RelayClient({ host: relay.host, webSocket: relay.factory, clock, visibility: null,
                                     random: () => 0, connectTimeoutMs: 1,
                                     credential: { kind: "signed", account, client: device, key: generateEd25519() } });
    client.start();
    const delays: number[] = [];
    for (let i = 0; i < 8; i++) {
      await clock.advance(1);
      const state = client.state;
      if (state.kind !== "unreachable") throw new Error(state.kind);
      delays.push(state.retryAt! - clock.now());
      await clock.advance(state.retryAt! - clock.now());
    }
    expect(delays).toEqual([800, 1600, 3200, 6400, 12_800, 24_000, 24_000, 24_000]);
  });

  it("4403 es relayRejected (no reintenta solo); 4409 es replaced", async () => {
    const { relay, clock, client } = setup();
    client.start();
    await flush();
    relay.last.drop(4403, "removed");
    await flush();
    expect(client.state).toEqual({ kind: "rejected", code: 4403 });
    await clock.advance(60_000);
    expect(client.state.kind).toBe("rejected");
    client.retryNow();
    await flush();
    expect(client.state.kind).toBe("ready");
    relay.last.drop(4409);
    await flush();
    expect(client.state).toEqual({ kind: "replaced" });
    await clock.advance(60_000);
    expect(client.state.kind).toBe("replaced");
  });

  it("se va a los 30 s en segundo plano y vuelve al primer plano", async () => {
    const { relay, clock, client, visibility } = setup();
    client.start();
    await flush();
    visibility.set(false);
    await clock.advance(29_000);
    expect(client.state.kind).toBe("ready");
    await clock.advance(1000);
    expect(client.state.kind).toBe("idle");
    expect(relay.open.length).toBe(0);
    visibility.set(true);
    await flush();
    expect(client.state.kind).toBe("ready");
    // Volver antes de los 30 s no corta.
    visibility.set(false);
    await clock.advance(10_000);
    visibility.set(true);
    await clock.advance(30_000);
    expect(client.state.kind).toBe("ready");
    expect(relay.open.length).toBe(1);
  });

  it("un ping sin pong en 5 s da la conexión por muerta y reconecta enseguida", async () => {
    const { relay, clock, client, states } = setup();
    client.start();
    await flush();
    const first = relay.last;
    first.dead = true;
    states.length = 0;
    await clock.advance(20_000);
    expect(first.sent.at(-1)).toEqual({ t: "ping" });
    expect(client.state.kind).toBe("ready");
    await clock.advance(PONG_TIMEOUT_MS);
    expect(first.closed).toBe(true);
    // Sin pasar por "unreachable": otra conexión enseguida.
    expect(states.map((s) => s.kind)).toEqual(["connecting", "ready"]);
    expect(relay.last).not.toBe(first);
  });

  it("un pong a tiempo no corta", async () => {
    const { relay, clock, client } = setup();
    client.start();
    await flush();
    await clock.advance(60_000);
    expect(client.state.kind).toBe("ready");
    expect(relay.sockets).toHaveLength(1);
  });

  it("al volver después de un rato oculto (página congelada) comprueba la conexión: muerta, reconecta", async () => {
    const { relay, clock, client, visibility, states } = setup();
    client.start();
    await flush();
    const first = relay.last;
    visibility.set(false);
    // iOS congela la página: ningún timer corre (ni el de 30 s en segundo plano) y el socket muere.
    clock.jump(5 * 60_000);
    first.dead = true;
    visibility.set(true);
    expect(client.state.kind).toBe("ready");
    expect(client.stale).toBe(true);
    expect(first.sent.at(-1)).toEqual({ t: "ping" });
    states.length = 0;
    await clock.advance(PONG_TIMEOUT_MS);
    expect(states.map((s) => s.kind)).toEqual(["connecting", "ready"]);
    expect(client.stale).toBe(false);
    expect(relay.open).toHaveLength(1);
  });

  it("al volver después de un rato oculto con la conexión viva: el pong la confirma y no reconecta", async () => {
    const { relay, clock, client, visibility } = setup();
    client.start();
    await flush();
    visibility.set(false);
    clock.jump(RESUME_CHECK_MS + 1000);
    visibility.set(true);
    expect(client.stale).toBe(true);
    await flush();
    expect(client.stale).toBe(false);
    await clock.advance(PONG_TIMEOUT_MS);
    expect(client.state.kind).toBe("ready");
    expect(relay.sockets).toHaveLength(1);
  });

  it("volver enseguida no manda ping extra", async () => {
    const { relay, client, visibility } = setup();
    client.start();
    await flush();
    visibility.set(false);
    visibility.set(true);
    expect(client.stale).toBe(false);
    expect(relay.last.sent.filter((m) => m.t === "ping")).toHaveLength(0);
  });

  it("callado hace más de 25 s está en duda aunque no se haya ocultado", async () => {
    const { clock, client } = setup();
    client.start();
    await flush();
    clock.jump(26_000);
    expect(client.stale).toBe(true);
    client.probe();
    await flush();
    expect(client.stale).toBe(false);
  });

  it("online: reintenta ya si estaba caído; settled espera el pong", async () => {
    const { relay, clock, client, visibility } = setup();
    client.start();
    await flush();
    relay.answers = false;
    relay.last.drop(1006);
    await flush();
    expect(client.state.kind).toBe("unreachable");
    relay.answers = true;
    visibility.wake();
    expect(client.state.kind).toBe("connecting");
    await flush();
    expect(client.state.kind).toBe("ready");
    // `settled` se resuelve con el pong de la comprobación.
    clock.jump(30_000);
    client.probe();
    let settled = false;
    void client.settled().then(() => (settled = true));
    await flush();
    expect(settled).toBe(true);
  });

  it("un corte con la página en segundo plano no muestra unreachable: reconecta al volver", async () => {
    const { relay, client, visibility, states } = setup();
    client.start();
    await flush();
    visibility.set(false);
    states.length = 0;
    relay.last.drop(1006);
    await flush();
    expect(states.map((s) => s.kind)).toEqual(["idle"]);
    visibility.set(true);
    await flush();
    expect(states.map((s) => s.kind)).toEqual(["idle", "connecting", "ready"]);
  });

  it("stop cierra y no reintenta", async () => {
    const { relay, clock, client } = setup();
    client.start();
    await flush();
    client.stop();
    expect(client.state.kind).toBe("idle");
    await clock.advance(60_000);
    expect(relay.open.length).toBe(0);
    expect(() => client.send({ t: "mbox.get" })).toThrow(RelayClosedError);
  });
});
