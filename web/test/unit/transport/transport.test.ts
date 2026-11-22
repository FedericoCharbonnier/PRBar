import { describe, expect, it } from "vitest";
import { ActionRunner } from "../../../src/app/actions";
import { passkeyAuthorizer } from "../../../src/presence/webauthn";
import { ed25519PublicKey, generateEd25519, generateX25519, x25519PublicKey } from "../../../src/crypto/curves";
import { sessionPrologue } from "../../../src/crypto/noise";
import type { RemoteFrame } from "../../../src/protocol/appFrames";
import { FakeTransport } from "../../../src/transport/FakeTransport";
import { LiveTransport, type LinkState } from "../../../src/transport/Transport";
import { CommandError, RemoteError } from "../../../src/transport/types";
import { fixture, type AppFixtureFile } from "../fixtures";
import { FakeRelay, flush, MacPeer, ManualClock } from "./harness";

const account = "hohrh3jbgktkby7euvoae3wjze";
const device = "fmh7nna7zna2bylvvuaupg6fnm";
const macHello: RemoteFrame = { t: "hello", remoteProtocol: 1, commandProtocol: 8, appVersion: "1.9.0", macName: "Studio" };

/** Un teléfono emparejado, un relay en memoria y una Mac que contesta cada handshake (una `MacPeer` por sesión). */
function setup(options: { hello?: RemoteFrame | null } = {}) {
  const relay = new FakeRelay();
  const clock = new ManualClock();
  const keys = { relay: generateEd25519(), noise: generateX25519(), push: generateX25519() };
  const macStatic = generateX25519();
  relay.devices.push({ account, device, relayKey: ed25519PublicKey(keys.relay) });
  const sessions: { mac: MacPeer; sid: string; socket: Parameters<FakeRelay["mac"]>[0] }[] = [];
  relay.mac = (socket, message) => {
    let current = sessions.find((s) => s.sid === message.sid);
    if (!current) {
      const mac = new MacPeer({ pattern: "kk", prologue: sessionPrologue(account, device), macStatic,
                                deviceStatic: keys.noise });
      current = { mac, sid: message.sid, socket };
      sessions.push(current);
      relay.fromMac(socket, message.sid, mac.answer(message.b).reply);
      return;
    }
    const frame = current.mac.open(message.b);
    if (frame?.t === "hello" && options.hello !== null) send(options.hello ?? macHello);
  };
  const send = (frame: RemoteFrame) => {
    const current = sessions.at(-1)!;
    for (const b of current.mac.seal(frame)) relay.fromMac(current.socket, current.sid, b);
  };
  const transport = new LiveTransport({
    paired: { accountId: account, deviceId: device, relayHost: relay.host, macName: "Mac",
              macStatic: x25519PublicKey(macStatic), macSeal: x25519PublicKey(generateX25519()) },
    keys, appVersion: "web-test", deviceName: "Phone", webSocket: relay.factory, clock, visibility: null,
    random: () => 0.5,
  });
  const states: LinkState[] = [];
  transport.subscribe((event) => { if (event.type === "state") states.push(event.state); });
  return { relay, clock, transport, sessions, send, states };
}

describe("LiveTransport", () => {
  it("con la Mac offline no abre sesión; cuando vuelve, sí", async () => {
    const t = setup();
    t.relay.macOnline = false;
    t.transport.start();
    await flush();
    expect(t.transport.state).toEqual({ kind: "macOffline", since: t.relay.macSince * 1000 });
    await expect(t.transport.send({ status: {} })).rejects.toMatchObject({ code: "macOffline" });
    t.relay.setMac(true);
    await flush();
    expect(t.transport.state).toEqual({ kind: "online" });
    expect(t.transport.macName).toBe("Studio");
  });

  it("una Mac que reconecta sin pasar por offline: sesión nueva y se vuelve a suscribir (M3)", async () => {
    const t = setup();
    t.transport.subscribeTopics(["home"]);
    t.transport.start();
    await flush();
    expect(t.sessions).toHaveLength(1);
    expect(t.sessions[0]!.mac.received.map((f) => f.t)).toEqual(["hello", "sub"]);
    t.relay.setMac(true);
    await flush();
    expect(t.sessions).toHaveLength(2);
    expect(t.sessions[1]!.mac.received).toContainEqual({ t: "sub", topics: ["home"] });
    expect(t.transport.state.kind).toBe("online");
  });

  it("send espera la conexión; un pedido vencido cierra la sesión y abre otra", async () => {
    const t = setup();
    const pending = t.transport.send({ status: {} });
    await flush();
    const { result, id } = await pending;
    expect(id).toBe(1);
    const failure = result.catch((e: unknown) => e);
    await t.clock.advance(60_000);
    expect(await failure).toMatchObject({ code: "timeout" });
    await flush();
    expect(t.sessions).toHaveLength(2);
    expect(t.transport.state.kind).toBe("online");
  });

  it("eventos: por opción y por `events(id)`, que repite los que ya llegaron", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    const seen: unknown[] = [];
    const { id, result } = await t.transport.send({ chatSend: { pr: "a/b#1", message: "hi" } },
                                                  { onEvent: (e) => seen.push(e) });
    t.send({ t: "res", id, event: { text: { delta: "a" } } });
    await flush();
    const late: unknown[] = [];
    t.transport.events(id, (e) => late.push(e));
    t.send({ t: "res", id, event: { text: { delta: "b" } } });
    t.send({ t: "res", id, ok: true, result: { ok: true } });
    expect(await result).toEqual({ ok: true });
    expect(seen).toEqual([{ text: { delta: "a" } }, { text: { delta: "b" } }]);
    expect(late).toEqual(seen);
  });

  it("presencePolicy: con Face ID apagado en la Mac no pide la passkey", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    t.send({ t: "presencePolicy", requirePresence: false, gated: ["merge"] });
    await flush();
    const merge = { merge: { pr: "a/b#1", confirmed: true, expectedHeadOid: "x" } };
    expect(t.transport.needsPresence(merge)).toBe(false);
    let asked = false;
    await t.transport.send(merge, { authorize: async () => { asked = true; throw new Error("no"); } });
    await flush();
    expect(asked).toBe(false);
    expect(t.sessions[0]!.mac.received.at(-1)).not.toHaveProperty("presence");
  });

  it("con la sesión abierta, Face ID se pide en el mismo toque: sin ningún await antes de credentials.get", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    expect(t.transport.state.kind).toBe("online");
    const gets: CredentialRequestOptions[] = [];
    const credentials = {
      create: async () => null,
      get: (options: CredentialRequestOptions) => {
        gets.push(options);
        return new Promise<Credential | null>(() => {});
      },
    };
    const presence = { credentialId: new Uint8Array(16), publicKey: new Uint8Array(91), rpId: "relay.example" };
    const runner = new ActionRunner(() => t.transport, () => passkeyAuthorizer(presence, credentials));
    // Lo que hace el click de "Merge": `run` sin esperar nada. Safari solo muestra Face ID si `credentials.get` se
    // llama antes de que termine el listener (ni un microtask después).
    void runner.run({ merge: { pr: "a/b#1", confirmed: true, expectedHeadOid: "x" } });
    expect(gets).toHaveLength(1);
    expect(gets[0]!.publicKey!.rpId).toBe("relay.example");
    expect(runner.faceIdPending.value).toBe(true);
  });

  it("sin la sesión abierta, un comando gated no pide Face ID después: falla y la sesión se abre", async () => {
    const t = setup();
    t.transport.start();
    expect(t.transport.state.kind).not.toBe("online");
    let asked = false;
    const merge = { merge: { pr: "a/b#1", confirmed: true, expectedHeadOid: "x" } };
    await expect(t.transport.send(merge, { authorize: async () => { asked = true; throw new Error("no"); } }))
      .rejects.toMatchObject({ code: "connecting" });
    expect(asked).toBe(false);
    await flush();
    expect(t.transport.state.kind).toBe("online");
    // Lo que no es gated sí espera la sesión.
    const pending = t.transport.send({ status: {} });
    await flush();
    expect((await pending).id).toBeGreaterThan(0);
  });

  it("con la conexión en duda (página congelada), un comando gated falla enseguida y la comprueba", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    expect(t.transport.state.kind).toBe("online");
    // iOS congeló la página un rato y el socket murió sin avisar.
    t.clock.jump(5 * 60_000);
    const first = t.relay.last;
    first.dead = true;
    let asked = false;
    const merge = { merge: { pr: "a/b#1", confirmed: true, expectedHeadOid: "x" } };
    const error = await t.transport.send(merge, { authorize: async () => { asked = true; throw new Error("no"); } })
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(RemoteError);
    expect(error).toMatchObject({ code: "connecting", message: "Still connecting to your Mac. Try again in a moment." });
    expect(asked).toBe(false);
    expect(first.sent.at(-1)).toEqual({ t: "ping" });
    // Sin pong: a los 5 s, conexión y sesión nuevas.
    await t.clock.advance(5000);
    expect(first.closed).toBe(true);
    expect(t.transport.state.kind).toBe("online");
    expect(t.sessions).toHaveLength(2);
  });

  it("con la conexión en duda, lo que no es gated espera la comprobación y sale por la conexión nueva", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    t.clock.jump(5 * 60_000);
    t.relay.last.dead = true;
    const pending = t.transport.send({ status: {} });
    await t.clock.advance(5000);
    const { id } = await pending;
    expect(id).toBe(1);
    expect(t.sessions).toHaveLength(2);
    expect(t.sessions[1]!.mac.received.at(-1)).toMatchObject({ t: "req", id: 1 });
  });

  it("un pedido en un socket que murió en primer plano falla en segundos, no en 60", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    t.clock.jump(10_000);
    t.relay.last.dead = true;
    const { result } = await t.transport.send({ status: {} });
    const failure = result.catch((e: unknown) => e);
    await t.clock.advance(5000);
    expect(await failure).toBeInstanceOf(RemoteError);
  });

  it("sin sesión y con la Mac offline, un comando gated dice que la Mac está offline", async () => {
    const t = setup();
    t.relay.macOnline = false;
    t.transport.start();
    await flush();
    const merge = { merge: { pr: "a/b#1", confirmed: true, expectedHeadOid: "x" } };
    await expect(t.transport.send(merge, { authorize: async () => { throw new Error("no"); } }))
      .rejects.toMatchObject({ code: "macOffline" });
  });

  it("hello incompatible: estado con el texto y sin reintentos", async () => {
    const t = setup({ hello: { ...macHello, incompatible: "updateMac" } as RemoteFrame });
    t.transport.start();
    await flush();
    expect(t.transport.state).toEqual({ kind: "incompatible", reason: "updateMac", message: "Update PRBar on your Mac." });
    await t.clock.advance(60_000);
    expect(t.sessions).toHaveLength(1);
    await expect(t.transport.send({ status: {} })).rejects.toMatchObject({ code: "incompatible" });
  });

  it("una Mac que no contesta el hello: reintenta con backoff", async () => {
    const t = setup({ hello: null });
    t.transport.start();
    await t.clock.advance(15_000);
    expect(t.sessions).toHaveLength(2);
    await t.clock.advance(15_000);
    expect(t.transport.state.kind).toBe("disconnected");
    await t.clock.advance(1000);
    expect(t.sessions).toHaveLength(3);
  });

  it("4403 del relay es relayRejected (no revoked) y undeliverable es Mac offline", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    t.relay.last.deliver({ t: "undeliverable", to: "mac", sid: t.sessions[0]!.sid });
    await flush();
    expect(t.transport.state).toEqual({ kind: "macOffline", since: null });
    t.relay.last.drop(4403);
    await flush();
    expect(t.transport.state).toEqual({ kind: "relayRejected", code: 4403 });
    // La próxima operación reintenta.
    const pending = await t.transport.send({ refresh: {} });
    expect(pending.id).toBe(1);
  });

  it("registra Web Push en cada conexión", async () => {
    const t = setup();
    t.transport.registerWebPush({ endpoint: "https://web.push.apple.com/x", p256dh: new Uint8Array(65),
                                  auth: new Uint8Array(16) });
    t.transport.start();
    await flush();
    t.relay.last.drop(1006);
    await t.clock.advance(1200);
    expect(t.relay.webpush).toHaveLength(2);
  });

  it("unpair avisa a la Mac y corta", async () => {
    const t = setup();
    t.transport.start();
    await flush();
    await t.transport.unpair();
    await flush();
    expect(t.sessions[0]!.mac.received.at(-1)).toEqual({ t: "unpair" });
    expect(t.transport.state).toEqual({ kind: "unpaired" });
    expect(t.relay.open).toHaveLength(0);
  });
});

describe("FakeTransport", () => {
  const app = fixture<AppFixtureFile>("app.json");

  it("contesta con app.json, emite eventos y sirve los tópicos", async () => {
    const fake = new FakeTransport(app);
    expect(fake.topic("home")?.prs).toHaveLength(3);
    expect(fake.topic("pr:acme/api#317")).toMatchObject({ slackChannel: "#api-reviews" });
    const events: unknown[] = [];
    const chat = await fake.run({ chatSend: { pr: "acme/api#317", message: "Anything else worth flagging?" } },
                                { onEvent: (e) => events.push(e) });
    expect(chat.messages).toHaveLength(2);
    expect(events).toHaveLength(2);
    const status = await fake.run({ status: {} });
    expect(status.badgeCount).toBe(3);
  });

  it("gated pide la passkey; sin ella falla; los errores y estados se pueden forzar", async () => {
    const fake = new FakeTransport(app);
    const merge = { merge: { pr: "acme/api#322", method: "squash" as const, confirmed: true, expectedHeadOid: "9f3c2a1" } };
    await expect(fake.send(merge)).rejects.toBeInstanceOf(RemoteError);
    let challenged = false;
    const merged = await fake.run(merge, { authorize: async () => {
      challenged = true;
      return { credentialId: new Uint8Array(1), authenticatorData: new Uint8Array(1), clientDataJSON: new Uint8Array(1),
               signature: new Uint8Array(1) };
    } });
    expect(challenged).toBe(true);
    expect(merged.method).toBe("squash");
    expect(fake.sent.at(-1)).toEqual({ command: merge, presence: true });

    fake.respond("refresh", () => new CommandError({ code: "failed", message: "Nope" }));
    await expect(fake.run({ refresh: {} })).rejects.toMatchObject({ message: "Nope" });
    fake.setState({ kind: "macOffline", since: null });
    await expect(fake.send({ status: {} })).rejects.toMatchObject({ code: "macOffline" });
  });
});
