import { describe, expect, it } from "vitest";
import rfc from "../../vectors/hpke-rfc9180-a23.json";
import { fromHex, toHex, utf8 } from "../../../src/crypto/bytes";
import { generateX25519, x25519PublicKey } from "../../../src/crypto/curves";
import {
  HPKEError, deriveKeyPair, mailboxInfo, openEnvelope, pad, pushIdentifiers, pushInfo, sealEnvelope, setupAuthR,
  setupAuthS, unpad,
} from "../../../src/crypto/hpke";

// RFC 9180 A.2.3: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305, modo Auth. El mismo vector que usa
// SealedTests.swift (copiado de github.com/cfrg/draft-irtf-cfrg-hpke test-vectors.json, mode 2 kem 0x20 kdf 1 aead 3).
describe("HPKE: RFC 9180 A.2.3 (modo auth)", () => {
  it("DeriveKeyPair da las claves del vector", () => {
    expect(toHex(deriveKeyPair(fromHex(rfc.ikmE)).privateKey)).toBe(rfc.skEm);
    expect(toHex(deriveKeyPair(fromHex(rfc.ikmR)).publicKey)).toBe(rfc.pkRm);
    expect(toHex(deriveKeyPair(fromHex(rfc.ikmS)).privateKey)).toBe(rfc.skSm);
  });

  it("el remitente produce enc, el key schedule y los textos cifrados del vector", () => {
    const s = setupAuthS(fromHex(rfc.pkRm), fromHex(rfc.info), fromHex(rfc.skSm), fromHex(rfc.skEm));
    expect(toHex(s.enc)).toBe(rfc.enc);
    expect(toHex(s.context.sharedSecret)).toBe(rfc.shared_secret);
    expect(toHex(s.context.keyScheduleContext)).toBe(rfc.key_schedule_context);
    expect(toHex(s.context.secret)).toBe(rfc.secret);
    expect(toHex(s.context.key)).toBe(rfc.key);
    expect(toHex(s.context.baseNonce)).toBe(rfc.base_nonce);
    expect(toHex(s.context.exporterSecret)).toBe(rfc.exporter_secret);
    for (const e of rfc.encryptions) expect(toHex(s.context.seal(fromHex(e.pt), fromHex(e.aad)))).toBe(e.ct);
  });

  it("el destinatario abre los textos cifrados del vector", () => {
    const r = setupAuthR(fromHex(rfc.enc), fromHex(rfc.skRm), fromHex(rfc.info), fromHex(rfc.pkSm));
    for (const e of rfc.encryptions) expect(toHex(r.open(fromHex(e.ct), fromHex(e.aad)))).toBe(e.pt);
  });

  it("otro remitente no abre", () => {
    const r = setupAuthR(fromHex(rfc.enc), fromHex(rfc.skRm), fromHex(rfc.info), x25519PublicKey(generateX25519()));
    expect(() => r.open(fromHex(rfc.encryptions[0]!.ct), fromHex(rfc.encryptions[0]!.aad))).toThrow(HPKEError);
  });
});

describe("relleno (Padding de Sealed.swift)", () => {
  it("len u32 BE ‖ datos ‖ ceros hasta múltiplo del bloque", () => {
    expect(toHex(pad(utf8("ab"), 8))).toBe("0000000261620000");
    expect(pad(new Uint8Array(252), 256).length).toBe(256);
    expect(pad(new Uint8Array(253), 256).length).toBe(512);
    expect(toHex(unpad(pad(utf8("hola"), 256)))).toBe(toHex(utf8("hola")));
  });

  it("rechaza largo imposible o relleno distinto de cero", () => {
    expect(() => unpad(fromHex("000000"))).toThrow(HPKEError);
    expect(() => unpad(fromHex("0000000561"))).toThrow(HPKEError);
    expect(() => unpad(fromHex("00000001610001"))).toThrow(HPKEError);
  });
});

describe("sobre (SealedEnvelope de Sealed.swift)", () => {
  const mac = generateX25519();
  const device = generateX25519();
  const info = pushInfo("acct", "dev1");

  it("info del push y del buzón", () => {
    expect(new TextDecoder().decode(pushInfo("acct", "dev1"))).toBe("PRBar push v1|acct|dev1");
    expect(new TextDecoder().decode(mailboxInfo("acct", "dev1", "home"))).toBe("PRBar mailbox v1|acct|dev1|home");
  });

  it("ida y vuelta; enc (32) ‖ cifrado de un múltiplo de 256 + tag", () => {
    const envelope = sealEnvelope(utf8("{\"v\":1}"), mac, x25519PublicKey(device), info);
    expect(envelope.length).toBe(32 + 256 + 16);
    expect(new TextDecoder().decode(openEnvelope(envelope, device, x25519PublicKey(mac), info))).toBe("{\"v\":1}");
  });

  it("otro remitente, otro info, un byte cambiado o un sobre corto fallan", () => {
    const envelope = sealEnvelope(utf8("x"), mac, x25519PublicKey(device), info);
    expect(() => openEnvelope(envelope, device, x25519PublicKey(generateX25519()), info)).toThrow(HPKEError);
    expect(() => openEnvelope(envelope, device, x25519PublicKey(mac), pushInfo("acct", "dev2"))).toThrow(HPKEError);
    const bad = envelope.slice();
    bad[40]! ^= 1;
    expect(() => openEnvelope(bad, device, x25519PublicKey(mac), info)).toThrow(HPKEError);
    expect(() => openEnvelope(envelope.slice(0, 51), device, x25519PublicKey(mac), info)).toThrow(HPKEError);
  });
});

describe("ids opacos del push (PushIdentifiers de Sealed.swift)", () => {
  it("los dos lados derivan lo mismo; collapse 64 hex, thread 32 hex", () => {
    const mac = generateX25519();
    const device = generateX25519();
    const phone = pushIdentifiers(device, x25519PublicKey(mac));
    const other = pushIdentifiers(mac, x25519PublicKey(device));
    expect(phone.collapse("approved", "acme/web#12")).toBe(other.collapse("approved", "acme/web#12"));
    expect(phone.collapse("approved", "acme/web#12")).toMatch(/^[0-9a-f]{64}$/);
    expect(phone.thread("acme/web#12")).toMatch(/^[0-9a-f]{32}$/);
    expect(phone.collapse("a", "bc")).not.toBe(phone.collapse("ab", "c"));
  });
});
