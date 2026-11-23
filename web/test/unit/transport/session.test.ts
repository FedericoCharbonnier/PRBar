import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { describe, expect, it } from "vitest";
import { b64urlDecode } from "../../../src/crypto/b64";
import { concat, randomBytes, type Bytes } from "../../../src/crypto/bytes";
import { generateX25519, x25519PublicKey } from "../../../src/crypto/curves";
import { sessionPrologue } from "../../../src/crypto/noise";
import { presenceChallenge } from "../../../src/crypto/presence";
import type { RemoteFrame } from "../../../src/protocol/appFrames";
import { encodeCommand } from "../../../src/protocol/commands";
import type { RelayMessage } from "../../../src/protocol/relayFrames";
import { Session, type SessionHandlers } from "../../../src/transport/Session";
import { RemoteError } from "../../../src/transport/types";
import { flush, MacPeer, ManualClock } from "./harness";

const account = "hohrh3jbgktkby7euvoae3wjze";
const device = "fmh7nna7zna2bylvvuaupg6fnm";
const macHello: RemoteFrame = { t: "hello", remoteProtocol: 1, commandProtocol: 8, appVersion: "1.9.0", macName: "Mac" };

function setup(handlers: SessionHandlers = {}) {
  const clock = new ManualClock();
  const deviceStatic = generateX25519();
  const macStatic = generateX25519();
  const wire: Extract<RelayMessage, { t: "send" }>[] = [];
  const session = new Session({
    account, device, deviceStatic, macStatic: x25519PublicKey(macStatic), appVersion: "web-0.1.0",
    deviceName: "Phone", clock, send: (m) => { if (m.t === "send") wire.push(m); },
  }, handlers);
  const mac = new MacPeer({ pattern: "kk", prologue: sessionPrologue(account, device), macStatic, deviceStatic });
  /** La Mac le manda marcos al teléfono. */
  const toPhone = (frame: RemoteFrame) => mac.seal(frame).forEach((b) => session.receive(b));
  /** Lo que el teléfono mandó desde la última vez, descifrado por la Mac. */
  let read = 0;
  const fromPhone = () => wire.slice(read).map((m) => { read++; return mac.open(m.b); }).filter((f) => f !== null);
  return { clock, session, mac, wire, toPhone, fromPhone, skipHandshake: () => { read = 1; } };
}

async function openSession(t: ReturnType<typeof setup>) {
  const opening = t.session.open();
  await flush();
  const { reply } = t.mac.answer(t.wire[0]!.b);
  t.session.receive(reply);
  t.skipHandshake();
  await flush();
  const [hello] = t.fromPhone();
  t.toPhone({ t: "presencePolicy", requirePresence: true, gated: ["merge"] });
  t.toPhone(macHello);
  return { hello, macHelloReceived: await opening };
}

describe("Session", () => {
  it("handshake KK y hello en los dos sentidos", async () => {
    const t = setup();
    const { hello, macHelloReceived } = await openSession(t);
    expect(hello).toEqual({ t: "hello", remoteProtocol: 1, commandProtocol: 8, appVersion: "web-0.1.0",
                            deviceName: "Phone" });
    expect(macHelloReceived.macName).toBe("Mac");
    expect(t.session.isOpen).toBe(true);
    expect(t.session.presencePolicy).toEqual({ requirePresence: true, gated: ["merge"] });
    expect(t.wire.every((m) => m.sid === t.session.sid && m.to === "mac")).toBe(true);
    expect(t.session.sid).toMatch(/^[0-9a-f]{16}$/);
  });

  it("pedido con eventos y respuesta; ids crecientes; deadline = sentAt + 60 s", async () => {
    const t = setup();
    await openSession(t);
    const events: unknown[] = [];
    const first = await t.session.request({ chatSend: { pr: "acme/api#317", message: "hi" } },
                                          { onEvent: (e) => events.push(e) });
    const second = await t.session.request({ status: {} });
    const [req1, req2] = t.fromPhone();
    expect(req1).toMatchObject({ t: "req", id: 1, sentAt: t.clock.now(), deadline: t.clock.now() + 60_000 });
    expect(req2).toMatchObject({ t: "req", id: 2 });
    t.toPhone({ t: "res", id: 1, event: { text: { delta: "Hel" } } });
    t.toPhone({ t: "res", id: 1, event: { text: { delta: "lo" } } });
    t.toPhone({ t: "res", id: 1, ok: true, result: { ok: true } });
    expect(await first.response).toEqual({ id: 1, ok: true, result: { ok: true } });
    expect(events).toEqual([{ text: { delta: "Hel" } }, { text: { delta: "lo" } }]);
    t.toPhone({ t: "res", id: 2, ok: false, error: { code: "failed", message: "Nope" } });
    expect((await second.response).error?.message).toBe("Nope");
  });

  it("la prueba de presencia firma el desafío de esta sesión, este id, estos bytes y esta hora", async () => {
    const t = setup();
    await openSession(t);
    const key = p256.utils.randomSecretKey();
    const credentialId = randomBytes(16);
    let challenge: Bytes | null = null;
    const command = { merge: { pr: "acme/api#322", method: "squash" as const, confirmed: true, expectedHeadOid: "9f3c2a1" } };
    await t.session.request(command, {
      authorize: async (c) => {
        challenge = Uint8Array.from(c);
        const authenticatorData = concat(sha256(new TextEncoder().encode("prbar.example.org")), Uint8Array.of(5),
                                         new Uint8Array(4));
        const clientDataJSON = new TextEncoder().encode(`{"type":"webauthn.get"}`);
        const signature = p256.sign(concat(authenticatorData, sha256(clientDataJSON)), key, { format: "der" });
        return { credentialId, authenticatorData, clientDataJSON, signature };
      },
    });
    const [req] = t.fromPhone();
    if (req?.t !== "req" || !req.presence) throw new Error("no presence");
    const expected = presenceChallenge(t.session.handshakeHash!, 1, encodeCommand(command), req.presence.ts);
    expect(challenge).toEqual(expected);
    expect(req.presence.ts).toBe(t.clock.now());
    expect(b64urlDecode(req.presence.credentialId)).toEqual(credentialId);
    expect(req.cmd).toEqual(encodeCommand(command));
  });

  it("un pedido sin respuesta vence solo; la sesión se prueba con un status y se cierra si tampoco contesta", async () => {
    const closed: RemoteError[] = [];
    const t = setup({ onClose: (e) => closed.push(e) });
    await openSession(t);
    const sent = await t.session.request({ refresh: {} });
    const result = sent.response.catch((e: unknown) => e);
    t.fromPhone();
    await t.clock.advance(60_000);
    expect(await result).toMatchObject({ code: "timeout" });
    await flush();
    expect(t.session.isOpen).toBe(true);
    const [probe] = t.fromPhone();
    expect(probe).toMatchObject({ t: "req", id: 2 });
    await t.clock.advance(15_000);
    await flush();
    expect(t.session.isClosed).toBe(true);
    expect(closed.map((e) => e.code)).toEqual(["sessionClosed"]);
  });

  it("si el status de prueba contesta, la sesión sigue y los otros pedidos también", async () => {
    const closed: RemoteError[] = [];
    const t = setup({ onClose: (e) => closed.push(e) });
    await openSession(t);
    const slow = (await t.session.request({ refresh: {} })).response.catch((e: unknown) => e);
    await t.clock.advance(30_000);
    const other = (await t.session.request({ status: {} })).response;
    await t.clock.advance(30_000);
    expect(await slow).toMatchObject({ code: "timeout" });
    await flush();
    const frames = t.fromPhone().filter((f) => f.t === "req");
    expect(frames.map((f) => f.t === "req" && f.id)).toEqual([1, 2, 3]);
    t.toPhone({ t: "res", id: 3, ok: true, result: { ok: true } });
    await flush();
    t.toPhone({ t: "res", id: 2, ok: true, result: { ok: true } });
    expect(await other).toMatchObject({ ok: true });
    await t.clock.advance(60_000);
    expect(t.session.isOpen).toBe(true);
    expect(closed).toEqual([]);
  });

  it("cada evento reinicia el tiempo límite; timeoutMs por pedido; el deadline sigue en 60 s", async () => {
    const t = setup();
    await openSession(t);
    const sent = await t.session.request({ chatSend: { pr: "acme/api#317", message: "hi" } }, { timeoutMs: 300_000 });
    const [req] = t.fromPhone();
    expect(req).toMatchObject({ t: "req", deadline: t.clock.now() + 60_000 });
    let settled = false;
    const result = sent.response.then((r) => { settled = true; return r; }, (e: unknown) => { settled = true; return e; });
    await t.clock.advance(240_000);
    t.toPhone({ t: "res", id: 1, event: { progress: { message: "Reading src/a.ts" } } });
    await t.clock.advance(240_000);
    await flush();
    expect(settled).toBe(false);
    t.toPhone({ t: "res", id: 1, ok: true, result: { ok: true } });
    expect(await result).toMatchObject({ ok: true });
  });

  it("state no vuelve atrás; chatDelta se reenvía", async () => {
    const states: number[] = [];
    const deltas: string[] = [];
    const t = setup({ onState: (u) => states.push(u.rev), onChatDelta: (_pr, text) => deltas.push(text) });
    await openSession(t);
    for (const rev of [1, 3, 2, 3, 4]) t.toPhone({ t: "state", topic: "home", rev, data: { prs: [] } });
    t.toPhone({ t: "chatDelta", pr: "acme/api#317", text: "from the Mac" });
    expect(states).toEqual([1, 3, 4]);
    expect(deltas).toEqual(["from the Mac"]);
  });

  it("bye(revoked) es una revocación; otro bye solo cierra", async () => {
    for (const [reason, code] of [["revoked", "revoked"], ["rotate", "sessionClosed"]] as const) {
      const closed: string[] = [];
      const t = setup({ onClose: (e) => closed.push(e.code) });
      await openSession(t);
      const pending = (await t.session.request({ status: {} })).response.catch((e: RemoteError) => e.code);
      t.toPhone({ t: "bye", reason });
      expect(closed).toEqual([code]);
      expect(await pending).toBe(code);
    }
  });

  it("un trozo que no autentica cierra la sesión", async () => {
    const closed: string[] = [];
    const t = setup({ onClose: (e) => closed.push(e.code) });
    await openSession(t);
    const [b] = t.mac.seal({ t: "chatDelta", pr: "a/b#1", text: "x" });
    b![0]! ^= 1;
    t.session.receive(b!);
    expect(closed).toEqual(["sessionClosed"]);
    await expect(t.session.request({ status: {} })).rejects.toMatchObject({ code: "sessionClosed" });
  });

  it("una Mac que no contesta: handshakeFailed", async () => {
    const t = setup();
    const opening = t.session.open().catch((e: unknown) => e);
    await t.clock.advance(15_000);
    expect(await opening).toMatchObject({ code: "handshakeFailed" });
  });

  it("hello incompatible", async () => {
    const t = setup();
    const opening = t.session.open().catch((e: unknown) => e);
    await flush();
    t.session.receive(t.mac.answer(t.wire[0]!.b).reply);
    await flush();
    t.toPhone({ ...macHello, incompatible: "updateIPhone" } as RemoteFrame);
    const error = await opening;
    expect(error).toBeInstanceOf(RemoteError);
    expect(error).toMatchObject({ code: "incompatible", incompatibility: "updateIPhone",
                                  message: "Update PRBar on this iPhone." });
  });

  it("rota a las 24 h: manda bye(rotate) y cierra", async () => {
    const closed: string[] = [];
    const t = setup({ onClose: (e) => closed.push(e.code) });
    await openSession(t);
    await t.clock.advance(24 * 3_600_000);
    t.session.subscribe(["home"]);
    const frames = t.fromPhone();
    expect(frames.map((f) => f.t)).toEqual(["sub", "bye"]);
    expect(frames[1]).toEqual({ t: "bye", reason: "rotate" });
    expect(closed).toEqual(["sessionClosed"]);
  });
});
