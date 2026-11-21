import { describe, expect, it } from "vitest";
import { b64urlEncode } from "../../../src/crypto/b64";
import { fromHex } from "../../../src/crypto/bytes";
import { fixture } from "../fixtures";
import { handlePush, openFromNotification, safeHash, type ClientsLike, type PushDeps, type WindowClientLike } from "../../../src/push/handler";
import { GENERIC_PUSH } from "../../../src/push/open";
import { ensureSubscription, fetchVapidKey, subscribePush, subscriptionKeys, type PushManagerLike, type PushSubscriptionLike } from "../../../src/push/subscribe";

function deps(overrides: Partial<PushDeps> = {}) {
  const shown: { title: string; options: NotificationOptions }[] = [];
  const seen: string[] = [];
  const badges: number[] = [];
  const d: PushDeps = {
    pushKeys: async () => null,
    seenIds: async () => [...seen],
    markSeen: async (id) => void seen.push(id),
    showNotification: async (title, options) => void shown.push({ title, options }),
    setBadge: async (n) => void badges.push(n),
    now: () => Date.parse("2026-11-20T12:40:00Z"),
    ...overrides,
  };
  return { d, shown, seen, badges };
}

describe("service worker: push", () => {
  it("siempre muestra algo: sin claves, sin datos o si algo falla, el genérico", async () => {
    for (const payload of [null, "{}", "not json", JSON.stringify({ v: 1, e: "AAAA" })]) {
      const { d, shown, seen } = deps();
      const n = await handlePush(payload, d);
      expect(n).toEqual(GENERIC_PUSH);
      expect(shown).toEqual([{ title: "PRBar", options: { body: "New activity on your Mac", tag: "prbar",
        data: { deepLink: "#/home" }, icon: "/icons/icon-192.png", badge: "/icons/icon-192.png" } }]);
      expect(seen).toEqual([]);
    }
    const broken = deps({ pushKeys: async () => { throw new Error("idb"); }, showNotification: async () => { throw new Error("no permission"); } });
    await expect(handlePush(JSON.stringify({ v: 1, e: "x" }), broken.d)).resolves.toEqual(GENERIC_PUSH);
  });
});

describe("service worker: push de la Mac", () => {
  interface HPKEFixture { kind: string; skR: string; pkS: string; envelopeB64url: string; collapse: string; thread: string; infoText: string }
  const vector = fixture<HPKEFixture[]>("hpke.json").find((h) => h.kind === "push")!;
  const [, account, device] = vector.infoText.split("|") as [string, string, string];
  const keys = { devicePush: fromHex(vector.skR), macSeal: fromHex(vector.pkS), account, device };
  const payload = JSON.stringify({ v: 1, e: vector.envelopeB64url, c: vector.collapse, th: vector.thread });

  it("descifra, muestra, anota el id y pone la insignia; repetido muestra el genérico", async () => {
    const { d, shown, seen, badges } = deps({ pushKeys: async () => keys });
    const n = await handlePush(payload, d);
    expect(shown[0]).toEqual({ title: "Ready to merge", options: {
      body: "acme/api#322 · Make payment retries idempotent", tag: "acme/api#322", data: { deepLink: "#/pr/acme/api/322/merge" },
      icon: "/icons/icon-192.png", badge: "/icons/icon-192.png" } });
    expect(seen).toEqual([n.id]);
    expect(badges).toEqual([2]);
    await handlePush(payload, d);
    expect(shown[1]!.title).toBe("PRBar");
    expect(seen).toHaveLength(1);
  });
});

describe("service worker: notificationclick", () => {
  it("enfoca la ventana abierta y la manda al link", async () => {
    const messages: unknown[] = [];
    let focused = 0;
    let opened: string | null = null;
    const window: WindowClientLike = { url: "https://relay.example.com/#/home", focus: async () => void focused++,
                                       postMessage: (m) => void messages.push(m) };
    const clients: ClientsLike = { matchAll: async () => [window], openWindow: async (url) => void (opened = url) };
    await openFromNotification("#/pr/acme/api/317/review", clients, "https://relay.example.com");
    expect(messages).toEqual([{ type: "prbar:navigate", hash: "#/pr/acme/api/317/review" }]);
    expect(focused).toBe(1);
    expect(opened).toBeNull();
  });

  it("sin ventana abre una; un link raro abre Home", async () => {
    let opened: string | null = null;
    const clients: ClientsLike = { matchAll: async () => [], openWindow: async (url) => void (opened = url) };
    await openFromNotification("javascript:alert(1)", clients, "https://relay.example.com");
    expect(opened).toBe("https://relay.example.com/#/home");
    expect(safeHash("#/activity")).toBe("#/activity");
    expect(safeHash("#/pr/a/b/1?x=<script>")).toBe("#/home");
  });
});

describe("Web Push: suscripción", () => {
  const vapid = Uint8Array.from({ length: 65 }, (_, i) => (i === 0 ? 4 : i));
  const fetcher = (status: number, body: unknown) => async () => ({ ok: status === 200, status, json: async () => body });

  it("lee la clave VAPID del relay", async () => {
    expect(await fetchVapidKey(fetcher(200, { publicKey: b64urlEncode(vapid) }))).toEqual(vapid);
    expect(await fetchVapidKey(fetcher(404, {}))).toBeNull();
    await expect(fetchVapidKey(fetcher(200, { publicKey: "AAAA" }))).rejects.toThrow();
    await expect(fetchVapidKey(fetcher(500, {}))).rejects.toThrow();
  });

  function manager(existing: PushSubscriptionLike | null) {
    const calls = { subscribed: [] as BufferSource[], unsubscribed: 0 };
    const sub = (key: Uint8Array): PushSubscriptionLike => ({
      endpoint: "https://web.push.apple.com/abc",
      options: { applicationServerKey: key.slice().buffer },
      getKey: (name) => (name === "p256dh" ? new Uint8Array(65).fill(4).buffer : new Uint8Array(16).fill(1).buffer),
      unsubscribe: async () => {
        calls.unsubscribed++;
        return true;
      },
    });
    const m: PushManagerLike = {
      getSubscription: async () => existing,
      subscribe: async (options) => {
        calls.subscribed.push(options.applicationServerKey);
        expect(options.userVisibleOnly).toBe(true);
        return sub(new Uint8Array(options.applicationServerKey as Uint8Array));
      },
    };
    return { m, calls, sub };
  }

  it("reusa la suscripción con la misma clave y rehace la de otra clave", async () => {
    const fresh = manager(null);
    const s = await ensureSubscription(fresh.m, vapid);
    expect(fresh.calls.subscribed).toHaveLength(1);
    const same = manager(s);
    expect(await ensureSubscription(same.m, vapid)).toBe(s);
    expect(same.calls.subscribed).toHaveLength(0);
    const other = manager(null);
    const old = other.sub(new Uint8Array(65).fill(9));
    other.m.getSubscription = async () => old;
    await ensureSubscription(other.m, vapid);
    expect(other.calls.unsubscribed).toBe(1);
    expect(other.calls.subscribed).toHaveLength(1);
  });

  it("registra endpoint y claves en el relay", async () => {
    const { m } = manager(null);
    const registered: unknown[] = [];
    const ok = await subscribePush({ manager: m, fetch: fetcher(200, { publicKey: b64urlEncode(vapid) }),
                                     register: (keys) => void registered.push(keys) });
    expect(ok).toBe(true);
    expect(registered).toEqual([{ endpoint: "https://web.push.apple.com/abc", p256dh: new Uint8Array(65).fill(4),
                                  auth: new Uint8Array(16).fill(1) }]);
    expect(await subscribePush({ manager: m, fetch: fetcher(404, {}), register: () => {} })).toBe(false);
    expect(() => subscriptionKeys({ endpoint: "x", getKey: () => null, unsubscribe: async () => true })).toThrow();
  });
});
