import { describe, expect, it } from "vitest";
import { fromHex, toHex } from "../../../src/crypto/bytes";
import { pairingProof, pairingSecrets } from "../../../src/crypto/relayAuth";
import { deepLinkToHash } from "../../../src/protocol/deepLinks";
import { isValidHost, PairingQRError, pairingURL, parsePairingURL } from "../../../src/protocol/pairingQR";
import { cleanText, displayName } from "../../../src/protocol/text";
import { helloIncompatibility } from "../../../src/protocol/version";
import { fixture } from "../fixtures";

interface QRFixture {
  valid: {
    url: string; relayHost: string; accountId: string; pairingId: string; secret: string; macStatic: string;
    macName: string; authKey: string; psk: string; nonce: string; proof: string;
  }[];
  invalid: string[];
}

const qr = fixture<QRFixture>("pairing-qr.json");

describe("pairing QR (pairing-qr.json)", () => {
  for (const [index, sample] of qr.valid.entries()) {
    it(`válido #${index}: campos, secretos derivados y el mismo URL de vuelta`, () => {
      const parsed = parsePairingURL(`  ${sample.url}\n`);
      expect(parsed.relayHost).toBe(sample.relayHost);
      expect(parsed.accountId).toBe(sample.accountId);
      expect(parsed.pairingId).toBe(sample.pairingId);
      expect(toHex(parsed.secret)).toBe(sample.secret);
      expect(toHex(parsed.macStatic)).toBe(sample.macStatic);
      expect(parsed.macName).toBe(sample.macName);
      expect(pairingURL(parsed)).toBe(sample.url);
      const secrets = pairingSecrets(parsed.secret);
      expect(toHex(secrets.authKey)).toBe(sample.authKey);
      expect(toHex(secrets.psk)).toBe(sample.psk);
      expect(toHex(pairingProof(secrets.authKey, fromHex(sample.nonce)))).toBe(sample.proof);
    });
  }

  for (const [index, url] of qr.invalid.entries()) {
    it(`inválido #${index}`, () => {
      expect(() => parsePairingURL(url)).toThrow(PairingQRError);
    });
  }

  it("un nombre con controles queda en una línea; uno vacío es Mac", () => {
    const base = qr.valid[0]!.url.replace(/&n=.*$/, "");
    expect(parsePairingURL(`${base}&n=Evil%E2%80%AE%0AMac`).macName).toBe("Evil Mac");
    expect(parsePairingURL(`${base}&n=%E2%80%8B`).macName).toBe("Mac");
    expect(() => parsePairingURL(`${base}&n=%E0%A4%A`)).toThrow(PairingQRError);
  });

  it("hosts", () => {
    expect(isValidHost("prbar.example.org:8443", false)).toBe(true);
    expect(isValidHost("127.0.0.1:8080", false)).toBe(false);
    expect(isValidHost("127.0.0.1:8080", true)).toBe(true);
    for (const bad of ["", "a b", "user@h.org", "h.org/x", "h.org:0", "h.org:70000", ".h.org", "-h.org", "h.org:"]) {
      expect(isValidHost(bad, true)).toBe(false);
    }
  });
});

describe("deep links", () => {
  it("mapea los links de la Mac a rutas por hash", () => {
    expect(deepLinkToHash("prbar://pr/acme/api/7?screen=respond")).toBe("#/pr/acme/api/7/respond");
    expect(deepLinkToHash("prbar://pr/acme/web-app/488")).toBe("#/pr/acme/web-app/488");
    expect(deepLinkToHash("prbar://pr/acme/api/322?screen=bogus")).toBe("#/pr/acme/api/322");
    expect(deepLinkToHash("prbar://activity")).toBe("#/activity");
    expect(deepLinkToHash("prbar://home")).toBe("#/home");
  });

  it("descarta lo que no es destino de una notificación", () => {
    for (const bad of ["prbar://pair?v=1", "https://evil.example/pr/a/b/1", "prbar://pr/a/b/0", "prbar://pr/a/b",
                       "prbar://pr/a/b/c/1", "prbar://pr/a%20b/c/1", "javascript:alert(1)"]) {
      expect(deepLinkToHash(bad)).toBeNull();
    }
  });
});

describe("texto", () => {
  it("saca escapes, bidi y controles", () => {
    expect(cleanText("a\u001b[31mred\u001b[0m\r\nb‮c\u0007")).toBe("ared\nbc");
    expect(cleanText("👨‍💻")).toBe("👨‍💻");
    expect(displayName("  one\ntwo\tthree  ")).toBe("one two three");
    expect(displayName("x".repeat(100), 10)).toBe("x".repeat(10));
  });
});

describe("versión", () => {
  const hello = { remoteProtocol: 1, commandProtocol: 8, appVersion: "1.9.0" };
  it("lo que dice la Mac y una Mac vieja", () => {
    expect(helloIncompatibility(hello)).toBeNull();
    expect(helloIncompatibility({ ...hello, incompatible: "updateIPhone" })).toBe("updateIPhone");
    expect(helloIncompatibility({ ...hello, commandProtocol: 7 })).toBe("updateMac");
  });
});
