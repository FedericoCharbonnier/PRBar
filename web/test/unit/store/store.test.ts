import { IDBFactory } from "fake-indexeddb";
import { describe, expect, it } from "vitest";
import { generateEd25519, generateX25519 } from "../../../src/crypto/curves";
import type { RemoteHome } from "../../../src/protocol/commands";
import { Cache } from "../../../src/store/cache";
import { getValue, openDatabase, write } from "../../../src/store/db";
import { KeyStore, type StoredPairing } from "../../../src/store/keys";
import { SeenIds } from "../../../src/store/seen";

const pairing = (): StoredPairing => ({
  mac: { accountId: "hohrh3jbgktkby7euvoae3wjze", deviceId: "fmh7nna7zna2bylvvuaupg6fnm", relayHost: "prbar.example.org",
         macName: "Mac", macStatic: new Uint8Array(32).fill(1), macSeal: new Uint8Array(32).fill(2) },
  keys: { relay: generateEd25519(), noise: generateX25519(), push: generateX25519() },
  presence: { credentialId: new Uint8Array(16).fill(3), publicKey: new Uint8Array(91).fill(4), rpId: "prbar.example.org" },
  deviceName: "iPhone",
  pairedAt: 1_795_178_280_000,
});

describe("KeyStore", () => {
  it("guarda y lee el emparejamiento; las privadas van envueltas con una clave no exportable", async () => {
    const indexedDB = new IDBFactory();
    const store = await KeyStore.open({ indexedDB });
    expect(await store.loadPairing()).toBeNull();
    const saved = pairing();
    await store.savePairing(saved);
    store.close();

    const again = await KeyStore.open({ indexedDB });
    expect(await again.loadPairing()).toEqual(saved);
    expect(await again.pushKeys()).toEqual({ devicePush: saved.keys.push, macSeal: saved.mac.macSeal,
                                             account: saved.mac.accountId, device: saved.mac.deviceId });

    // Lo que queda en IndexedDB: la clave de envoltura no se puede exportar y las privadas no están en claro.
    const db = await openDatabase({ indexedDB });
    const wrapKey = await getValue<CryptoKey>(db, "keys", "wrapKey");
    expect(wrapKey?.extractable).toBe(false);
    await expect(crypto.subtle.exportKey("raw", wrapKey!)).rejects.toThrow();
    const raw = JSON.stringify(await getValue(db, "keys", "pairing"), (_k, v: unknown) =>
      v instanceof ArrayBuffer ? Array.from(new Uint8Array(v)) : v instanceof Uint8Array ? Array.from(v) : v);
    for (const key of Object.values(saved.keys)) expect(raw).not.toContain(JSON.stringify(Array.from(key)).slice(1, -1));
    db.close();
    again.close();
  });

  it("sin la clave de envoltura (iOS borró datos) el emparejamiento no se puede abrir", async () => {
    const indexedDB = new IDBFactory();
    const store = await KeyStore.open({ indexedDB });
    await store.savePairing(pairing());
    const db = await openDatabase({ indexedDB });
    await write(db, ["keys"], (s) => s("keys").delete("wrapKey"));
    expect(await store.hasPairing()).toBe(true);
    expect(await store.loadPairing()).toBeNull();
    expect(await store.pushKeys()).toBeNull();
    db.close();
    await store.clear();
    expect(await store.hasPairing()).toBe(false);
  });

  it("una privada envuelta no se puede hacer pasar por otra", async () => {
    const indexedDB = new IDBFactory();
    const store = await KeyStore.open({ indexedDB });
    await store.savePairing(pairing());
    const db = await openDatabase({ indexedDB });
    const record = await getValue<{ wrapped: Record<string, unknown> }>(db, "keys", "pairing");
    record!.wrapped.push = record!.wrapped.relay;
    await write(db, ["keys"], (s) => s("keys").put(record, "pairing"));
    expect(await store.loadPairing()).toBeNull();
    db.close();
  });
});

describe("Cache", () => {
  const home = { status: { appVersion: "1", refreshing: false, offline: false, badgeCount: 1, counts: {}, issues: [],
                           slackIssues: [], jobs: [], accounts: [], tools: [] }, prs: [], ci: [] } as RemoteHome;

  it("home, PRs con LRU, revisiones del buzón, y se borra todo", async () => {
    const indexedDB = new IDBFactory();
    const cache = await Cache.open({ indexedDB, maxPRs: 3 });
    await cache.saveHome(home, 10);
    expect(await cache.loadHome()).toEqual({ home, updatedAt: 10 });
    for (const n of [1, 2, 3]) await cache.savePR(`a/b#${n}`, { slackChannel: `#${n}` }, n);
    // Usar el 1 lo salva: se va el 2, el menos usado.
    expect(await cache.loadPR("a/b#1")).toEqual({ detail: { slackChannel: "#1" }, updatedAt: 1 });
    await cache.savePR("a/b#4", {}, 4);
    expect(await cache.loadPR("a/b#2")).toBeNull();
    expect(await cache.loadPR("a/b#3")).not.toBeNull();
    await cache.saveMailboxRevisions({ home: 5 });
    expect(await cache.loadMailboxRevisions()).toEqual({ home: 5 });
    cache.close();

    // El orden del LRU sobrevive a reabrir.
    const again = await Cache.open({ indexedDB, maxPRs: 3 });
    await again.savePR("a/b#5", {}, 5);
    expect(await again.loadPR("a/b#1")).toBeNull();
    await again.clear();
    expect(await again.loadHome()).toBeNull();
    expect(await again.loadPR("a/b#4")).toBeNull();
    expect(await again.loadMailboxRevisions()).toEqual({});
  });

  it("por defecto guarda 50 PRs", async () => {
    const cache = await Cache.open({ indexedDB: new IDBFactory() });
    for (let n = 1; n <= 52; n++) await cache.savePR(`a/b#${n}`, {}, n);
    expect(await cache.loadPR("a/b#2")).toBeNull();
    expect(await cache.loadPR("a/b#3")).not.toBeNull();
  });
});

describe("SeenIds", () => {
  it("recuerda los últimos 200", async () => {
    const seen = await SeenIds.open({ indexedDB: new IDBFactory() });
    for (let i = 0; i < 205; i++) await seen.add(`id-${i}`);
    const ids = await seen.list();
    expect(ids).toHaveLength(200);
    expect(ids[0]).toBe("id-5");
    expect(await seen.has("id-4")).toBe(false);
    expect(await seen.has("id-204")).toBe(true);
    await seen.add("id-5");
    expect((await seen.list()).at(-1)).toBe("id-5");
    await seen.clear();
    expect(await seen.list()).toEqual([]);
  });
});
