import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { fromHex, toHex } from "../../../src/crypto/bytes";
import { ed25519PublicKey, x25519PublicKey } from "../../../src/crypto/curves";
import { openEnvelope, sealEnvelope } from "../../../src/crypto/hpke";
import { presenceChallenge } from "../../../src/crypto/presence";
import { relayAuthMessage, verifyRelayAuth } from "../../../src/crypto/relayAuth";
import { sasCode } from "../../../src/crypto/sas";
import { runNoiseVector, type NoiseVector } from "./noiseRunner";

// Vectores cruzados que genera la Mac (`prbar-remote-fixture vectors web/test/fixtures/`, tarea A3). Mientras no
// existan, estos tests se saltean. Formato esperado (bytes en hex; cada archivo puede ser un objeto o una lista):
// - noise-kk.json, noise-ikpsk2.json: el formato de cacophony (ver noiseRunner.ts).
// - hpke.json: { info, skR, pkS, plaintext, envelope, skS?, skE? } — `envelope` = enc ‖ ciphertext del sobre
//   rellenado (SealedEnvelope); con `skS` y `skE` también se comprueba que sellar da los mismos bytes.
// - sas.json: { handshakeHash, code }.
// - relay-auth.json: { publicKey, host, acct, client, nonce, sig, privateKey? } — la firma Ed25519 de CryptoKit no es
//   determinista, así que se verifica (no se compara).
// - presence.json: { sessionHash, reqId, cmd, ts, challenge } — `reqId` y `ts` como números.

const dir = new URL("../../fixtures/", import.meta.url);

function load<T>(name: string): T[] | undefined {
  const url = new URL(name, dir);
  if (!existsSync(url)) return undefined;
  const data = JSON.parse(readFileSync(url, "utf8")) as T | T[];
  return Array.isArray(data) ? data : [data];
}

function suite<T>(name: string, run: (item: T) => void) {
  const items = load<T>(name);
  describe.skipIf(!items)(`fixtures/${name}`, () => {
    (items ?? []).forEach((item, index) => it(`#${index}`, () => run(item)));
  });
}

suite<NoiseVector>("noise-kk.json", runNoiseVector);
suite<NoiseVector>("noise-ikpsk2.json", runNoiseVector);

suite<{ info: string; skR: string; pkS: string; plaintext: string; envelope: string; skS?: string; skE?: string }>(
  "hpke.json", (v) => {
    expect(toHex(openEnvelope(fromHex(v.envelope), fromHex(v.skR), fromHex(v.pkS), fromHex(v.info)))).toBe(v.plaintext);
    if (v.skS && v.skE) {
      expect(toHex(x25519PublicKey(fromHex(v.skS)))).toBe(v.pkS);
      const sealed = sealEnvelope(fromHex(v.plaintext), fromHex(v.skS), x25519PublicKey(fromHex(v.skR)), fromHex(v.info),
        fromHex(v.skE));
      expect(toHex(sealed)).toBe(v.envelope);
    }
  });

suite<{ handshakeHash: string; code: string }>("sas.json", (v) => {
  expect(sasCode(fromHex(v.handshakeHash))).toBe(v.code);
});

suite<{ publicKey: string; host: string; acct: string; client: string; nonce: string; sig: string; privateKey?: string }>(
  "relay-auth.json", (v) => {
    if (v.privateKey) expect(toHex(ed25519PublicKey(fromHex(v.privateKey)))).toBe(v.publicKey);
    expect(relayAuthMessage(v.host, v.acct, v.client, fromHex(v.nonce)).length).toBeGreaterThan(0);
    expect(verifyRelayAuth(fromHex(v.sig), fromHex(v.publicKey), v.host, v.acct, v.client, fromHex(v.nonce))).toBe(true);
  });

suite<{ sessionHash: string; reqId: number; cmd: string; ts: number; challenge: string }>("presence.json", (v) => {
  expect(toHex(presenceChallenge(fromHex(v.sessionHash), v.reqId, fromHex(v.cmd), v.ts))).toBe(v.challenge);
});
