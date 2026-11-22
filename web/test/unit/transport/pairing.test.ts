import { describe, expect, it } from "vitest";
import { toHex } from "../../../src/crypto/bytes";
import { generateX25519, x25519PublicKey } from "../../../src/crypto/curves";
import { pairingPrologue } from "../../../src/crypto/noise";
import { pairingSecrets } from "../../../src/crypto/relayAuth";
import { decodePairingMessage, encodePairingMessage } from "../../../src/protocol/appFrames";
import { pairingURL } from "../../../src/protocol/pairingQR";
import { startPairing } from "../../../src/transport/Pairing";
import { RemoteError } from "../../../src/transport/types";
import { FakeRelay, flush, MacPeer, ManualClock } from "./harness";

// Emparejamiento contra un relay en memoria y una Mac de prueba. El caso del vector (`noise-ikpsk2.json`, con las
// efímeras fijas) está en integration.test.ts; acá van los caminos de error.

const account = "hohrh3jbgktkby7euvoae3wjze";
const pairing = "wkgc5nrkicgkayji";

function setup() {
  const relay = new FakeRelay();
  const clock = new ManualClock();
  const secret = new Uint8Array(32).fill(7);
  const macStatic = generateX25519();
  relay.pairings.set(pairing, { account, authKey: pairingSecrets(secret).authKey });
  const url = pairingURL({ relayHost: relay.host, accountId: account, pairingId: pairing, secret,
                           macStatic: x25519PublicKey(macStatic), macName: "Work Mac" });
  const mac = new MacPeer({ pattern: "ikpsk2", prologue: pairingPrologue(account, pairing), macStatic,
                            psk: pairingSecrets(secret).psk });
  return { relay, clock, url, mac, secret };
}

const presence = { credentialId: new Uint8Array(16).fill(3), publicKey: new Uint8Array(91).fill(4), rpId: "prbar.example.org" };

describe("Pairing", () => {
  it("SAS, confirm, resultado y acuse", async () => {
    const { relay, clock, url, mac } = setup();
    relay.mac = (socket, message) => {
      if (!mac.transport) {
        const { payload, reply } = mac.answer(message.b);
        const join = decodePairingMessage(payload);
        expect(join.kind === "join" && join.join.deviceName).toBe("My Phone");
        relay.fromMac(socket, message.sid, reply);
        return;
      }
      const decoded = decodePairingMessage(mac.transport.receive.decrypt(message.b));
      if (decoded.kind === "confirm") {
        relay.fromMac(socket, message.sid, mac.transport.send.encrypt(encodePairingMessage({
          kind: "result", result: { deviceId: "fmh7nna7zna2bylvvuaupg6fnm", macName: "Work‮ Mac",
                                    macSeal: new Uint8Array(32).fill(9), relayHost: relay.host } })));
      } else {
        expect(decoded.kind).toBe("ack");
        // La Mac cierra la ranura después del acuse: no pisa el resultado.
        socket.drop(1000);
      }
    };
    const session = await startPairing({ qr: url, deviceName: "My Phone", model: "iPhone", presence,
                                         webSocket: relay.factory, clock });
    expect(session.sas).toMatch(/^\d{6}$/);
    expect(session.sasDisplay).toBe(`${session.sas.slice(0, 3)} ${session.sas.slice(3)}`);
    await flush();
    const outcome = await session.finish();
    expect(outcome.mac).toMatchObject({ accountId: account, deviceId: "fmh7nna7zna2bylvvuaupg6fnm", relayHost: relay.host,
                                        macName: "Work Mac" });
    expect(toHex(outcome.mac.macSeal)).toBe("09".repeat(32));
    expect(outcome.presence).toBe(presence);
    expect(outcome.keys.relay.length).toBe(32);
  });

  it("la Mac cancela", async () => {
    const { relay, clock, url, mac } = setup();
    relay.mac = (socket, message) => {
      if (!mac.transport) return relay.fromMac(socket, message.sid, mac.answer(message.b).reply);
      relay.fromMac(socket, message.sid, mac.transport.send.encrypt(encodePairingMessage({ kind: "cancelled" })));
    };
    const session = await startPairing({ qr: url, deviceName: "P", model: "iPhone", presence: null,
                                         webSocket: relay.factory, clock });
    await expect(session.finish()).rejects.toMatchObject({ code: "pairingCancelled" });
  });

  it("una ranura vencida (el relay no acepta la prueba): pairingExpired", async () => {
    const { relay, clock, url } = setup();
    relay.pairings.clear();
    await expect(startPairing({ qr: url, deviceName: "P", model: "iPhone", presence: null, webSocket: relay.factory,
                                clock })).rejects.toMatchObject({ code: "pairingExpired" });
  });

  it("una Mac que no contesta: pairingExpired a los 15 s", async () => {
    const { relay, clock, url } = setup();
    const result = startPairing({ qr: url, deviceName: "P", model: "iPhone", presence: null, webSocket: relay.factory,
                                  clock }).catch((e: unknown) => e);
    await clock.advance(15_000);
    expect(await result).toMatchObject({ code: "pairingExpired" });
    expect(relay.open.length).toBe(0);
  });

  it("otra Mac (otra estática): el handshake no autentica", async () => {
    const { relay, clock, url, secret } = setup();
    const impostor = new MacPeer({ pattern: "ikpsk2", prologue: pairingPrologue(account, pairing),
                                   macStatic: generateX25519(), psk: pairingSecrets(secret).psk });
    relay.mac = (socket, message) => {
      try {
        relay.fromMac(socket, message.sid, impostor.answer(message.b).reply);
      } catch {
        socket.drop(1000);
      }
    };
    const error = await startPairing({ qr: url, deviceName: "P", model: "iPhone", presence: null,
                                       webSocket: relay.factory, clock }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(RemoteError);
  });

  it("cancel suelta la ranura", async () => {
    const { relay, clock, url, mac } = setup();
    relay.mac = (socket, message) => {
      if (!mac.transport) relay.fromMac(socket, message.sid, mac.answer(message.b).reply);
    };
    const session = await startPairing({ qr: url, deviceName: "P", model: "iPhone", presence: null,
                                         webSocket: relay.factory, clock });
    session.cancel();
    expect(relay.open.length).toBe(0);
    await expect(session.finish()).rejects.toMatchObject({ code: "pairingCancelled" });
  });

});
