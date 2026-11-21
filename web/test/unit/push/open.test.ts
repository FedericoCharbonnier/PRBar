import { describe, expect, it } from "vitest";
import { b64urlEncode } from "../../../src/crypto/b64";
import { fromHex, utf8 } from "../../../src/crypto/bytes";
import { generateX25519 } from "../../../src/crypto/curves";
import { pushInfo, sealEnvelope } from "../../../src/crypto/hpke";
import { swiftJSON } from "../../../src/protocol/json";
import { GENERIC_PUSH, openPush } from "../../../src/push/open";
import type { PushKeys } from "../../../src/store/keys";
import { fixture } from "../fixtures";

interface HPKEFixture {
  kind: string; skR: string; skS: string; pkR: string; pkS: string; envelopeB64url: string; collapse: string;
  thread: string; infoText: string;
}

const vector = fixture<HPKEFixture[]>("hpke.json").find((h) => h.kind === "push")!;
const [, account, device] = vector.infoText.split("|") as [string, string, string];
const keys: PushKeys = { devicePush: fromHex(vector.skR), macSeal: fromHex(vector.pkS), account, device };
const created = Date.UTC(2026, 10, 20, 12, 38);
const none = { has: () => false };
const payload = (e: string) => JSON.stringify({ v: 1, e, c: vector.collapse, th: vector.thread });

/** Un push sellado como la Mac (para los casos que el vector no cubre). */
function seal(content: Record<string, unknown>): string {
  const plaintext = utf8(swiftJSON({ v: 1, id: "A-1", createdAt: "2026-11-20T12:38:00Z", kind: "readyToMerge",
                                     title: "Ready to Merge", body: "api#322", threadId: "acme/api#322",
                                     deepLink: "prbar://home", ...content }));
  return payload(b64urlEncode(sealEnvelope(plaintext, fromHex(vector.skS), fromHex(vector.pkR),
                                           pushInfo(account, device))));
}

describe("openPush", () => {
  it("abre el sobre de la Mac (hpke.json)", () => {
    expect(openPush(payload(vector.envelopeB64url), keys, created + 60_000, none)).toEqual({
      title: "Ready to merge", body: "acme/api#322 · Make payment retries idempotent", tag: "acme/api#322",
      deepLink: "#/pr/acme/api/322/merge", badge: 2, id: "6F1D8C2E-0B7A-4E55-9C61-3A2B9E0F4D11",
    });
  });

  it("los tres pushes de app.json (con sus deep links)", () => {
    const pushes = fixture<{ push: Record<string, unknown>[] }>("app.json").push;
    const routes = pushes.map((p) => openPush(seal(p), keys, created, none).deepLink);
    expect(routes).toEqual(["#/pr/acme/api/7/respond", "#/pr/acme/api/322/merge", "#/activity"]);
  });

  it("genérico si es viejo, del futuro o ya visto", () => {
    const text = payload(vector.envelopeB64url);
    expect(openPush(text, keys, created + 24 * 3_600_000, none).id).toBeDefined();
    expect(openPush(text, keys, created + 24 * 3_600_000 + 1, none)).toEqual(GENERIC_PUSH);
    expect(openPush(text, keys, created - 10 * 60_000, none).id).toBeDefined();
    expect(openPush(text, keys, created - 10 * 60_000 - 1, none)).toEqual(GENERIC_PUSH);
    const seen = new Set(["6F1D8C2E-0B7A-4E55-9C61-3A2B9E0F4D11"]);
    expect(openPush(text, keys, created, seen)).toEqual(GENERIC_PUSH);
  });

  it("genérico si no descifra o no tiene la forma esperada", () => {
    const tampered = vector.envelopeB64url.slice(0, 60) + (vector.envelopeB64url[60] === "A" ? "B" : "A")
      + vector.envelopeB64url.slice(61);
    const otherKeys = { ...keys, devicePush: generateX25519() };
    for (const [text, k] of [
      [payload(tampered), keys], [payload(vector.envelopeB64url), otherKeys],
      [payload(vector.envelopeB64url), { ...keys, device: "otherdevice" }], [payload(vector.envelopeB64url), null],
      ["not json", keys], [JSON.stringify({ v: 2, e: vector.envelopeB64url }), keys], [payload("AQID"), keys],
      [JSON.stringify({ v: 1 }), keys], [seal({ v: 2 }), keys], [seal({ title: 3 }), keys],
      [seal({ createdAt: "yesterday" }), keys],
    ] as const) {
      expect(openPush(text, k, created, none)).toEqual(GENERIC_PUSH);
    }
  });

  it("limpia los textos y descarta links que no son destinos", () => {
    const shown = openPush(seal({ title: "Ready‮\nto merge", body: "a\u001b[31mb\u0007", badge: -1,
                                  deepLink: "prbar://pair?v=1" }), keys, created, none);
    expect(shown).toEqual({ title: "Ready to merge", body: "ab", tag: "acme/api#322", deepLink: "#/home", id: "A-1" });
  });
});
