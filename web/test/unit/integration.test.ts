import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { describe, expect, it } from "vitest";
import { b64urlDecode, b64urlEncode } from "../../src/crypto/b64";
import { concat, fromHex, toHex, utf8 } from "../../src/crypto/bytes";
import { ed25519PublicKey } from "../../src/crypto/curves";
import { pairingPrologue, sessionPrologue } from "../../src/crypto/noise";
import { presenceChallenge } from "../../src/crypto/presence";
import { decodeFrame, decodePairingMessage, type RemoteFrame } from "../../src/protocol/appFrames";
import { encodeCommand } from "../../src/protocol/commands";
import { startPairing, type PairingOutcome } from "../../src/transport/Pairing";
import { LiveTransport, type TransportEvent } from "../../src/transport/Transport";
import { fixture, type AppFixtureFile, type NoiseFixture } from "./fixtures";
import { FakeRelay, flush, MacPeer, ManualClock } from "./transport/harness";

// El teléfono entero (emparejamiento, sesión, comandos, Face ID, tópicos, buzón) contra un relay en memoria y una Mac
// guionada con los vectores que genera la Mac: con las mismas claves y efímeras, los bytes que manda la web tienen que
// ser los de Swift.

const ik = fixture<NoiseFixture[]>("noise-ikpsk2.json")[0]!;
const kk = fixture<NoiseFixture[]>("noise-kk.json")[0]!;
const qr = fixture<{ valid: { url: string }[] }>("pairing-qr.json").valid[0]!;
const relayAuth = fixture<{ privateKey: string; publicKey: string; client: string }[]>("relay-auth.json")[0]!;
const hpke = fixture<{ kind: string; skR: string; skS: string; envelope: string }[]>("hpke.json");
const presence = fixture<{ privateKey?: string; credential?: { credentialId: string; publicKey: string; rpId: string };
                           origin?: string }[]>("presence.json")[0]!;
const app = fixture<AppFixtureFile>("app.json");

const deviceKeys = {
  relay: fromHex(relayAuth.privateKey),
  noise: fromHex(ik.init_static),
  push: fromHex(hpke.find((h) => h.kind === "push")!.skR),
};
const credential = {
  credentialId: b64urlDecode(presence.credential!.credentialId),
  publicKey: b64urlDecode(presence.credential!.publicKey),
  rpId: presence.credential!.rpId,
};
const ciphertext = (vector: NoiseFixture, i: number) => vector.messages[i]!.ciphertext;

async function pair(relay: FakeRelay, clock: ManualClock): Promise<PairingOutcome> {
  const mac = new MacPeer({ pattern: "ikpsk2", prologue: pairingPrologue(ik.account, ik.pairing!),
                            macStatic: fromHex(ik.resp_static), psk: fromHex(ik.resp_psks![0]!),
                            fixedEphemeral: fromHex(ik.resp_ephemeral) });
  relay.pairings.set(ik.pairing!, { account: ik.account, authKey: fromHex(ik.pairAuthKey!) });
  const seen: string[] = [];
  relay.mac = (socket, message) => {
    seen.push(toHex(message.b));
    if (seen.length === 1) {
      const { payload, reply } = mac.answer(message.b);
      expect(new TextDecoder().decode(payload)).toBe(ik.messages[0]!.frame);
      expect(toHex(reply)).toBe(ciphertext(ik, 1));
      relay.fromMac(socket, message.sid, reply);
    } else if (seen.length === 2) {
      expect(decodePairingMessage(mac.transport!.receive.decrypt(message.b)).kind).toBe("confirm");
      // "Codes Match" en la Mac.
      const result = mac.transport!.send.encrypt(fromHex(ik.messages[3]!.payload));
      expect(toHex(result)).toBe(ciphertext(ik, 3));
      relay.fromMac(socket, message.sid, result);
    } else {
      expect(decodePairingMessage(mac.transport!.receive.decrypt(message.b)).kind).toBe("ack");
    }
  };
  const session = await startPairing({
    qr: qr.url, deviceName: "Federico’s iPhone", model: "iPhone", presence: credential, keys: deviceKeys,
    webSocket: relay.factory, clock, fixedEphemeral: fromHex(ik.init_ephemeral),
  });
  expect(session.sas).toBe(ik.sas);
  expect(session.sasDisplay).toBe("899 366");
  const outcome = await session.finish();
  await flush();
  // Los cinco mensajes del vector, byte a byte (los del teléfono los armó la web).
  expect(seen).toEqual([ciphertext(ik, 0), ciphertext(ik, 2), ciphertext(ik, 4)]);
  return outcome;
}

/** Una Mac guionada para la sesión KK del vector: contesta el handshake con la efímera fija y deja que el test mande
 *  marcos. Comprueba que lo que cifra es lo del vector mientras sigue el guion. */
function scriptedMac(relay: FakeRelay) {
  const mac = new MacPeer({ pattern: "kk", prologue: sessionPrologue(kk.account, kk.device),
                            macStatic: fromHex(kk.resp_static), deviceStatic: fromHex(kk.init_static),
                            fixedEphemeral: fromHex(kk.resp_ephemeral) });
  const fromPhone: string[] = [];
  let socket: Parameters<FakeRelay["mac"]>[0] | null = null;
  let sid = "";
  relay.mac = (from, message) => {
    socket = from;
    sid = message.sid;
    fromPhone.push(toHex(message.b));
    if (fromPhone.length === 1) {
      const { reply } = mac.answer(message.b);
      relay.fromMac(from, sid, reply);
    } else {
      mac.open(message.b);
    }
  };
  const send = (frame: RemoteFrame) => {
    const chunks = mac.seal(frame);
    for (const b of chunks) relay.fromMac(socket!, sid, b);
    return chunks.map(toHex);
  };
  return { mac, fromPhone, send };
}

describe("de punta a punta con los vectores de la Mac", () => {
  it("empareja, abre la sesión, manda comandos con Face ID, se suscribe, lee el buzón y respeta la revocación",
     async () => {
    const relay = new FakeRelay();
    const clock = new ManualClock();
    const outcome = await pair(relay, clock);
    expect(outcome.mac).toEqual({
      accountId: ik.account, deviceId: ik.device, relayHost: "prbar.example.org", macName: "Federico’s MacBook Pro",
      macStatic: fromHex(ik.init_remote_static), macSeal: fromHex(ik.macSeal!),
    });
    expect(toHex(ed25519PublicKey(outcome.keys.relay))).toBe(ik.deviceRelayPublic);

    // La Mac dio de alta el dispositivo en el relay.
    relay.devices.push({ account: ik.account, device: ik.device, relayKey: ed25519PublicKey(outcome.keys.relay) });
    const mac = scriptedMac(relay);
    const transport = new LiveTransport({
      paired: outcome.mac, keys: outcome.keys, appVersion: "web-0.1.0", deviceName: "Federico’s iPhone",
      webSocket: relay.factory, clock, visibility: null, random: () => 0.5,
      sessionSeed: () => ({ fixedEphemeral: fromHex(kk.init_ephemeral) }),
    });
    const events: TransportEvent[] = [];
    transport.subscribe((event) => events.push(event));
    transport.registerWebPush({ endpoint: "https://web.push.apple.com/QGuQ", p256dh: new Uint8Array(65).fill(4),
                                auth: new Uint8Array(16).fill(1) });
    transport.start();
    await flush();

    // Handshake KK + hello del teléfono: los bytes del vector.
    expect(mac.fromPhone).toEqual([ciphertext(kk, 0), ciphertext(kk, 2)]);
    expect(relay.webpush).toHaveLength(1);
    expect(mac.send(decodeFrame(utf8(kk.messages[3]!.frame!)))).toEqual([ciphertext(kk, 3)]);
    await flush();
    expect(transport.state).toEqual({ kind: "online" });
    expect(transport.macName).toBe("Federico’s MacBook Pro");

    // Un comando: el `req` lleva los bytes exactos de `{"status":{}}`.
    const status = transport.run({ status: {} });
    await flush();
    const req = mac.mac.received.at(-1)!;
    expect(req).toMatchObject({ t: "req", id: 1, sentAt: clock.now(), deadline: clock.now() + 60_000 });
    expect(req.t === "req" && new TextDecoder().decode(req.cmd)).toBe(`{"status":{}}`);
    expect(mac.send(decodeFrame(utf8(kk.messages[5]!.frame!)))).toEqual([ciphertext(kk, 5)]);

    // `sub`: el sexto mensaje del vector, byte a byte.
    transport.subscribeTopics(["home", "pr:acme/api#317", "home", "not a topic"]);
    await flush();
    expect(mac.fromPhone.at(-1)).toBe(ciphertext(kk, 6));
    expect(mac.send(decodeFrame(utf8(kk.messages[7]!.frame!)))).toEqual([ciphertext(kk, 7)]);
    await flush();
    // El `home` del vector es solo `{"prs":[]}` (sin `status`): no es un home válido y se ignora.
    expect(transport.topic("home")).toBeUndefined();
    expect(events.some((e) => e.type === "topic" && e.name === "home")).toBe(false);

    // La respuesta de `status` (la de app.json) resuelve el pedido.
    const statusSample = app.commands.find((c) => c.name === "status")!;
    mac.send({ t: "res", ...(statusSample.response as { id: number }), id: 1 } as RemoteFrame);
    expect((await status).badgeCount).toBe(3);

    // Un tópico completo de app.json.
    const home = app.topics.find((t) => t.topic === "home")!;
    mac.send({ t: "state", topic: "home", rev: 2, data: JSON.parse(home.text) });
    await flush();
    expect(transport.topic("home")?.prs).toHaveLength(3);
    expect(events).toContainEqual({ type: "topic", name: "home" });

    // Merge con Face ID: la Mac recalcula el desafío y verifica la firma con la SPKI del emparejamiento.
    const key = fromHex(presence.privateKey!);
    const merge = { merge: { pr: "acme/api#322", method: "squash" as const, confirmed: true, expectedHeadOid: "9f3c2a1" } };
    expect(transport.needsPresence(merge)).toBe(true);
    await expect(transport.send(merge)).rejects.toMatchObject({ code: "presenceRequired" });
    const pending = await transport.send(merge, {
      authorize: async (challenge) => {
        const authenticatorData = concat(sha256(utf8(credential.rpId)), Uint8Array.of(0x05), new Uint8Array(4));
        const clientDataJSON = utf8(JSON.stringify({ type: "webauthn.get", challenge: b64urlEncode(challenge),
                                                     origin: presence.origin, crossOrigin: false }));
        const signature = p256.sign(concat(authenticatorData, sha256(clientDataJSON)), key, { format: "der" });
        return { credentialId: credential.credentialId, authenticatorData, clientDataJSON, signature };
      },
    });
    await flush();
    const mergeReq = mac.mac.received.at(-1)!;
    if (mergeReq.t !== "req" || !mergeReq.presence) throw new Error("no proof");
    const proof = mergeReq.presence;
    const clientData = JSON.parse(new TextDecoder().decode(b64urlDecode(proof.clientDataJSON))) as { challenge: string };
    const expected = presenceChallenge(fromHex(kk.handshake_hash), mergeReq.id, encodeCommand(merge), proof.ts);
    expect(clientData.challenge).toBe(b64urlEncode(expected));
    const spki = credential.publicKey;
    const publicKey = spki.slice(spki.length - 65);
    const signed = concat(b64urlDecode(proof.authenticatorData), sha256(b64urlDecode(proof.clientDataJSON)));
    expect(p256.verify(b64urlDecode(proof.signature), signed, publicKey, { format: "der" })).toBe(true);
    expect(b64urlDecode(proof.credentialId)).toEqual(credential.credentialId);
    const mergeSample = app.commands.find((c) => c.name === "merge")!;
    mac.send({ t: "res", ...(mergeSample.response as object), id: mergeReq.id } as RemoteFrame);
    expect(await pending.result).toMatchObject({ pr: "acme/api#322", method: "squash" });

    // Un error de la Mac llega tal cual.
    const refused = await transport.send({ refresh: {} });
    await flush();
    expect(mac.mac.received.at(-1)).toMatchObject({ t: "req", id: refused.id });
    mac.send({ t: "res", id: refused.id, ok: false,
               error: { code: "invalidState", message: "This request expired. Try again." } });
    await expect(refused.result).rejects.toMatchObject({ code: "invalidState",
                                                         message: "This request expired. Try again." });

    // Buzón: el sobre del vector (hpke.json) abre con la clave de push.
    const mailbox = hpke.find((h) => h.kind === "mailbox")!;
    relay.mailbox = [{ slot: "home", b: fromHex(mailbox.envelope), at: 1_795_178_280 }];
    const blobs = await transport.mailbox();
    expect(blobs).toHaveLength(1);
    expect(blobs[0]).toMatchObject({ slot: "home", rev: 1_795_178_280_000, createdAt: "2026-11-20T12:38:00Z" });
    expect(new TextDecoder().decode(blobs[0]!.data)).toBe(`{"prs":[]}`);
    expect(transport.mailboxRevisions).toEqual({ home: 1_795_178_280_000 });

    // La Mac revoca: `bye(revoked)` dentro de la sesión.
    mac.send({ t: "bye", reason: "revoked" });
    await flush();
    expect(transport.state).toEqual({ kind: "revoked" });
    expect(relay.open).toHaveLength(0);
    await expect(transport.send({ status: {} })).rejects.toMatchObject({ code: "revoked" });
  });
});
