import { createHash, createHmac, createPublicKey, hkdfSync, verify } from "node:crypto";
import { describe, expect, it } from "vitest";
import { b64urlEncode } from "../../../src/crypto/b64";
import { concat, fromHex, i64BE, toHex, u64BE, utf8 } from "../../../src/crypto/bytes";
import { ed25519PublicKey, ed25519Sign, ed25519Verify, generateEd25519 } from "../../../src/crypto/curves";
import { presenceChallenge, presenceProofJSON } from "../../../src/crypto/presence";
import {
  pairingProof, pairingSecrets, relayAuthMessage, signRelayAuth, signedHost, verifyRelayAuth,
} from "../../../src/crypto/relayAuth";
import { sasCode, sasDisplay } from "../../../src/crypto/sas";

const nodeEd25519Verify = (pub: Uint8Array, message: Uint8Array, sig: Uint8Array) =>
  verify(null, message, createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: b64urlEncode(pub) }, format: "jwk" }), sig);

describe("SAS (SAS.swift)", () => {
  it("los mismos códigos que SASTests.swift", () => {
    expect(sasCode(new Uint8Array(32))).toBe("745502");
    expect(sasCode(Uint8Array.from({ length: 32 }, (_, i) => i))).toBe("425641");
  });

  it("siempre 6 dígitos; se muestra como \"123 456\"", () => {
    for (let i = 0; i < 50; i++) expect(sasCode(crypto.getRandomValues(new Uint8Array(32)))).toMatch(/^\d{6}$/);
    expect(sasDisplay("012345")).toBe("012 345");
  });
});

describe("Ed25519", () => {
  it("RFC 8032 §7.1 TEST 1", () => {
    const sk = fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    expect(toHex(ed25519PublicKey(sk))).toBe("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    expect(toHex(ed25519Sign(new Uint8Array(0), sk))).toBe(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
  });
});

describe("auth del relay (RelayAuth de RelayMessages.swift)", () => {
  const nonce = fromHex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");

  it("mensaje: \"PRBarRelayAuth v1\\n\" ‖ host ‖ \"\\n\" ‖ cuenta ‖ \"\\n\" ‖ cliente ‖ \"\\n\" ‖ nonce", () => {
    expect(toHex(relayAuthMessage("relay.example.com", "acct", "dev", nonce)))
      .toBe(toHex(concat(utf8("PRBarRelayAuth v1\nrelay.example.com\nacct\ndev\n"), nonce)));
  });

  it("se firma el host sin puerto (RelayTransport.swift)", () => {
    expect(signedHost("relay.example.com:8443")).toBe("relay.example.com");
    expect(signedHost("relay.example.com")).toBe("relay.example.com");
  });

  it("la firma verifica con otra implementación (node:crypto) y no sirve con otro host", () => {
    const key = generateEd25519();
    const sig = signRelayAuth(key, "relay.example.com:8443", "acct", "dev", nonce);
    const pub = ed25519PublicKey(key);
    expect(nodeEd25519Verify(pub, relayAuthMessage("relay.example.com", "acct", "dev", nonce), sig)).toBe(true);
    expect(verifyRelayAuth(sig, pub, "relay.example.com", "acct", "dev", nonce)).toBe(true);
    expect(verifyRelayAuth(sig, pub, "other.example.com", "acct", "dev", nonce)).toBe(false);
    expect(ed25519Verify(sig.slice(1), new Uint8Array(0), pub)).toBe(false);
  });
});

describe("secretos del emparejamiento (PairingSecrets de RemoteKeys.swift)", () => {
  it("authKey y psk = HKDF-SHA256(ps, sal vacía, info, 32); proof = HMAC(authKey, nonce)", () => {
    const ps = Uint8Array.from({ length: 32 }, (_, i) => 255 - i);
    const nonce = utf8("nonce");
    const { authKey, psk } = pairingSecrets(ps);
    const expected = (info: string) => toHex(new Uint8Array(hkdfSync("sha256", ps, new Uint8Array(0), info, 32)));
    expect(toHex(authKey)).toBe(expected("PRBar relay pairing v1"));
    expect(toHex(psk)).toBe(expected("PRBar noise psk v1"));
    expect(toHex(pairingProof(authKey, nonce))).toBe(createHmac("sha256", authKey).update(nonce).digest("hex"));
  });
});

describe("desafío de presencia v2 (spec W.5)", () => {
  const sessionHash = Uint8Array.from({ length: 32 }, (_, i) => i);
  const cmd = utf8("{\"merge\":{\"pr\":\"acme/api#322\"}}");

  it("SHA256(\"PRBarPresence v2\" ‖ sessionHash ‖ reqId u64 BE ‖ SHA256(cmd) ‖ ts i64 BE ms)", () => {
    const ts = 1_800_000_000_123;
    const expected = createHash("sha256")
      .update(utf8("PRBarPresence v2")).update(sessionHash).update(u64BE(42))
      .update(createHash("sha256").update(cmd).digest()).update(i64BE(ts)).digest("hex");
    expect(toHex(presenceChallenge(sessionHash, 42, cmd, ts))).toBe(expected);
    expect(toHex(presenceChallenge(sessionHash, 42n, cmd, BigInt(ts)))).toBe(expected);
  });

  it("cambia con cada parte", () => {
    const base = toHex(presenceChallenge(sessionHash, 1, cmd, 1000));
    expect(toHex(presenceChallenge(sessionHash, 2, cmd, 1000))).not.toBe(base);
    expect(toHex(presenceChallenge(sessionHash, 1, utf8("x"), 1000))).not.toBe(base);
    expect(toHex(presenceChallenge(sessionHash, 1, cmd, 1001))).not.toBe(base);
    expect(toHex(presenceChallenge(new Uint8Array(32), 1, cmd, 1000))).not.toBe(base);
    expect(() => presenceChallenge(new Uint8Array(31), 1, cmd, 1000)).toThrow();
  });

  it("la prueba viaja como JSON con bytes en base64url", () => {
    expect(presenceProofJSON({
      tsMillis: 5, credentialId: fromHex("01"), authenticatorData: fromHex("02"), clientDataJSON: utf8("{}"),
      signature: fromHex("ff"),
    })).toEqual({ v: 2, ts: 5, credentialId: "AQ", authenticatorData: "Ag", clientDataJSON: "e30", signature: "_w" });
  });
});
