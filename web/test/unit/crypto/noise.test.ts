import { describe, expect, it } from "vitest";
import vectors from "../../vectors/noise.json";
import { concat, fromHex, toHex, utf8 } from "../../../src/crypto/bytes";
import { generateX25519, x25519PublicKey } from "../../../src/crypto/curves";
import { NoiseError, NoiseHandshake, pairingPrologue, sessionPrologue } from "../../../src/crypto/noise";
import { runNoiseVector, type NoiseVector } from "./noiseRunner";

function kkPair(prologue = utf8("p")) {
  const a = generateX25519();
  const b = generateX25519();
  const i = new NoiseHandshake({ pattern: "kk", initiator: true, prologue, localStatic: a, remoteStatic: x25519PublicKey(b) });
  const r = new NoiseHandshake({ pattern: "kk", initiator: false, prologue, localStatic: b, remoteStatic: x25519PublicKey(a) });
  r.readMessage(i.writeMessage());
  i.readMessage(r.writeMessage());
  return { i, r, a: i.split(), b: r.split() };
}

function code(f: () => unknown): string | undefined {
  try {
    f();
  } catch (e) {
    return e instanceof NoiseError ? e.code : `other: ${String(e)}`;
  }
  return undefined;
}

// test/vectors/noise.json es el JSON de NoiseVectors.swift sin tocar: cacophony (commit 8ee9d41e), entradas
// Noise_KK_25519_ChaChaPoly_SHA256 y Noise_IKpsk2_25519_ChaChaPoly_SHA256, y snow (commit 8ac60f51), entrada KK.
describe("noise: vectores oficiales (los de NoiseVectors.swift)", () => {
  const all = vectors as NoiseVector[];

  it("incluye KK con hash final e IKpsk2", () => {
    expect(all.some((v) => v.protocol_name === "Noise_KK_25519_ChaChaPoly_SHA256" && v.handshake_hash)).toBe(true);
    expect(all.some((v) => v.protocol_name === "Noise_IKpsk2_25519_ChaChaPoly_SHA256")).toBe(true);
  });

  for (const v of all) {
    it(`${v.source} ${v.protocol_name}`, () => runNoiseVector(v));
  }
});

describe("noise: sesión", () => {
  it("ida y vuelta en las dos direcciones; el hash de handshake coincide", () => {
    const { i, r, a, b } = kkPair();
    expect(toHex(i.handshakeHash)).toBe(toHex(r.handshakeHash));
    expect(toHex(b.receive.decrypt(a.send.encrypt(utf8("hola"))))).toBe(toHex(utf8("hola")));
    expect(toHex(a.receive.decrypt(b.send.encrypt(utf8("chau"))))).toBe(toHex(utf8("chau")));
    expect(a.send.n).toBe(1n);
  });

  it("un byte cambiado rompe la sesión (y no se puede seguir usando)", () => {
    const { a, b } = kkPair();
    const m1 = a.send.encrypt(utf8("uno"));
    const bad = m1.slice();
    bad[0]! ^= 1;
    expect(code(() => b.receive.decrypt(bad))).toBe("decryptFailed");
    expect(b.receive.isBroken).toBe(true);
    expect(code(() => b.receive.decrypt(m1))).toBe("invalidState");
  });

  it("un mensaje repetido o fuera de orden no autentica", () => {
    const { a, b } = kkPair();
    const m1 = a.send.encrypt(utf8("uno"));
    const m2 = a.send.encrypt(utf8("dos"));
    expect(code(() => b.receive.decrypt(m2))).toBe("decryptFailed");
    const fresh = kkPair();
    const n1 = fresh.a.send.encrypt(utf8("uno"));
    fresh.b.receive.decrypt(n1);
    expect(code(() => fresh.b.receive.decrypt(n1))).toBe("decryptFailed");
    void m1;
  });

  it("otro prólogo no completa el handshake", () => {
    const a = generateX25519();
    const b = generateX25519();
    const i = new NoiseHandshake({ pattern: "kk", initiator: true, prologue: utf8("x"), localStatic: a, remoteStatic: x25519PublicKey(b) });
    const r = new NoiseHandshake({ pattern: "kk", initiator: false, prologue: utf8("y"), localStatic: b, remoteStatic: x25519PublicKey(a) });
    expect(code(() => r.readMessage(i.writeMessage()))).toBe("decryptFailed");
    expect(code(() => r.writeMessage())).toBe("invalidState");
  });

  it("fuera de turno, split antes de terminar y configuración inválida", () => {
    const a = generateX25519();
    const b = generateX25519();
    const i = new NoiseHandshake({ pattern: "kk", initiator: true, prologue: utf8(""), localStatic: a, remoteStatic: x25519PublicKey(b) });
    expect(code(() => i.readMessage(new Uint8Array(48)))).toBe("invalidState");
    expect(code(() => i.split())).toBe("invalidState");
    expect(code(() => new NoiseHandshake({ pattern: "kk", initiator: true, prologue: utf8(""), localStatic: a, remoteStatic: null })))
      .toBe("invalidConfiguration");
    expect(code(() => new NoiseHandshake({ pattern: "ikpsk2", initiator: true, prologue: utf8(""), localStatic: a, remoteStatic: x25519PublicKey(b), psk: new Uint8Array(31) })))
      .toBe("invalidConfiguration");
    expect(code(() => new NoiseHandshake({ pattern: "ikpsk2", initiator: false, prologue: utf8(""), localStatic: a, remoteStatic: x25519PublicKey(b), psk: new Uint8Array(32) })))
      .toBe("invalidConfiguration");
  });

  it("mensaje corto es malformado; transporte > 65 535 es demasiado grande", () => {
    const a = generateX25519();
    const b = generateX25519();
    const r = new NoiseHandshake({ pattern: "kk", initiator: false, prologue: utf8(""), localStatic: b, remoteStatic: x25519PublicKey(a) });
    expect(code(() => r.readMessage(new Uint8Array(10)))).toBe("malformed");
    const { a: t } = kkPair();
    expect(code(() => t.send.encrypt(new Uint8Array(65_535 - 16 + 1)))).toBe("messageTooLarge");
    expect(t.send.encrypt(new Uint8Array(65_535 - 16)).length).toBe(65_535);
  });

  it("el nonce 2⁶⁴−1 está reservado", () => {
    const { a } = kkPair();
    a.send._setNonceForTesting((1n << 64n) - 2n);
    a.send.encrypt(utf8("último"));
    expect(code(() => a.send.encrypt(utf8("uno más")))).toBe("nonceExhausted");
  });

  it("una efímera de orden bajo (secreto en cero) se rechaza", () => {
    const a = generateX25519();
    const b = generateX25519();
    const r = new NoiseHandshake({ pattern: "kk", initiator: false, prologue: utf8(""), localStatic: b, remoteStatic: x25519PublicKey(a) });
    expect(code(() => r.readMessage(concat(new Uint8Array(32), new Uint8Array(16))))).toBe("decryptFailed");
  });

  it("IKpsk2: el respondedor aprende la estática del iniciador; otro psk falla", () => {
    const phone = generateX25519();
    const mac = generateX25519();
    const psk = new Uint8Array(32).fill(7);
    const i = new NoiseHandshake({ pattern: "ikpsk2", initiator: true, prologue: utf8("p"), localStatic: phone, remoteStatic: x25519PublicKey(mac), psk });
    const r = new NoiseHandshake({ pattern: "ikpsk2", initiator: false, prologue: utf8("p"), localStatic: mac, remoteStatic: null, psk });
    r.readMessage(i.writeMessage(utf8("join")));
    expect(toHex(r.remoteStaticKey!)).toBe(toHex(x25519PublicKey(phone)));
    i.readMessage(r.writeMessage());
    expect(toHex(i.handshakeHash)).toBe(toHex(r.handshakeHash));

    const i2 = new NoiseHandshake({ pattern: "ikpsk2", initiator: true, prologue: utf8("p"), localStatic: phone, remoteStatic: x25519PublicKey(mac), psk });
    const r2 = new NoiseHandshake({ pattern: "ikpsk2", initiator: false, prologue: utf8("p"), localStatic: mac, remoteStatic: null, psk: new Uint8Array(32).fill(8) });
    r2.readMessage(i2.writeMessage());
    expect(code(() => i2.readMessage(r2.writeMessage()))).toBe("decryptFailed");
  });
});

describe("prólogos (RemotePrologue de RemoteKeys.swift)", () => {
  it("sesión: \"PRBar Remote v1\" ‖ cuenta ‖ 0x00 ‖ dispositivo", () => {
    expect(toHex(sessionPrologue("acct", "dev"))).toBe(toHex(concat(utf8("PRBar Remote v1acct"), fromHex("00"), utf8("dev"))));
  });

  it("emparejamiento: \"PRBar Pair v1\" ‖ cuenta ‖ 0x00 ‖ id de emparejamiento", () => {
    expect(toHex(pairingPrologue("acct", "pid"))).toBe(toHex(concat(utf8("PRBar Pair v1acct"), fromHex("00"), utf8("pid"))));
  });
});
