import { describe, expect, it } from "vitest";
import { ActionFailure } from "../../../src/app/actions";
import { parseUnifiedDiff } from "../../../src/app/diff";
import {
  age, ago, bytes, chatStamp, clock, count, dayAndTime, duration, initials, lineOf, money, repoName, shortRef, time,
} from "../../../src/app/format";
import { defaultDeviceName, deviceModel, isStandalone, platformOf } from "../../../src/app/install";
import { HOME, parentRoute, parseRoute, routeHash, Router } from "../../../src/app/router";
import { CommandError } from "../../../src/transport/types";
import { makeApp, NOW } from "./helpers";

const L = { locale: "en-US", timeZone: "UTC" };

describe("format", () => {
  it("nombres y referencias", () => {
    expect(repoName("acme/web-app")).toBe("web-app");
    expect(shortRef("acme/web-app#491")).toBe("web-app#491");
    expect(initials("Laura Méndez")).toBe("LM");
    expect(initials("lmendez")).toBe("LM");
    expect(initials("ana-pereira")).toBe("AP");
    expect(count(1, "comment")).toBe("1 comment");
    expect(count(4, "comment")).toBe("4 comments");
    expect(lineOf("src/a.ts:88")).toBe(88);
    expect(lineOf("src/a.ts")).toBeNull();
  });

  it("edades y horas", () => {
    expect(age(NOW - 30_000, NOW)).toBe("now");
    expect(age(NOW - 12 * 60_000, NOW)).toBe("12 min");
    expect(age(NOW - 2 * 3_600_000, NOW)).toBe("2h");
    expect(age(NOW - 3 * 86_400_000, NOW)).toBe("3d");
    expect(age(NOW - 15 * 86_400_000, NOW)).toBe("2w");
    expect(ago(NOW - 4 * 60_000, NOW)).toBe("4m ago");
    const at812 = Date.parse("2026-11-20T08:12:00Z");
    expect(time(at812, L)).toBe("8:12 AM");
    expect(dayAndTime(at812, NOW, L)).toBe("today at 8:12 AM");
    expect(dayAndTime(at812 - 86_400_000, NOW, L)).toBe("yesterday at 8:12 AM");
    expect(dayAndTime(at812 - 2 * 86_400_000, NOW, L)).toBe("Nov 18 at 8:12 AM");
    expect(chatStamp(at812, NOW, L)).toBe("Today 8:12 AM");
  });

  it("números", () => {
    expect(clock(252)).toBe("4:12");
    expect(clock(3723)).toBe("1:02:03");
    expect(duration(220)).toBe("3m 40s");
    expect(duration(45)).toBe("45s");
    expect(money(48.2)).toBe("$48.20");
    expect(bytes(11_200_000_000)).toBe("11.2 GB");
    expect(bytes(212_000_000_000)).toBe("212 GB");
    expect(bytes(640_000_000)).toBe("640 MB");
  });
});

describe("diff", () => {
  it("parte un diff unificado en archivos y líneas", () => {
    const files = parseUnifiedDiff([
      "diff --git a/src/a.ts b/src/a.ts",
      "index 1..2 100644",
      "--- a/src/a.ts",
      "+++ b/src/a.ts",
      "@@ -10,3 +10,4 @@ fn",
      " keep",
      "-old",
      "+new",
      "+more",
      "diff --git a/b.ts b/b.ts",
      "@@ -1 +1 @@",
      "-x",
      "+y",
      "",
    ].join("\n"), ["b.ts"]);
    expect(files.map((f) => [f.path, f.name, f.additions, f.deletions, f.sensitive])).toEqual([
      ["src/a.ts", "a.ts", 2, 1, false], ["b.ts", "b.ts", 1, 1, true],
    ]);
    expect(files[0]!.lines).toEqual([
      { kind: "hunk", text: "@@ -10,3 +10,4 @@ fn" },
      { kind: "context", number: 10, text: "keep" },
      { kind: "del", number: 11, text: "old" },
      { kind: "add", number: 11, text: "new" },
      { kind: "add", number: 12, text: "more" },
    ]);
  });
});

describe("router", () => {
  it("parsea y arma las rutas por hash", () => {
    expect(parseRoute("#/pr/acme/api/3/diff?file=src%2Fa%20b.ts")).toEqual({ kind: "pr", pr: "acme/api#3", screen: "diff", file: "src/a b.ts" });
    expect(routeHash({ kind: "pr", pr: "acme/api#3", screen: "diff", file: "src/a b.ts" })).toBe("#/pr/acme/api/3/diff?file=src%2Fa%20b.ts");
    expect(parseRoute("#/pr/acme/api/3/fixci?file=x")).toEqual({ kind: "pr", pr: "acme/api#3", screen: "fixci" });
    expect(parseRoute("")).toEqual(HOME);
    expect(parseRoute("#/home")).toEqual(HOME);
    expect(parseRoute("#/mine")).toEqual({ kind: "tab", tab: "mine" });
    expect(parseRoute("#/activity")).toEqual({ kind: "tab", tab: "activity" });
    expect(parseRoute("#/settings")).toEqual({ kind: "tab", tab: "settings" });
    expect(parseRoute("#/pair")).toEqual({ kind: "pair" });
    expect(parseRoute("#/pr/acme/api/317")).toEqual({ kind: "pr", pr: "acme/api#317" });
    expect(parseRoute("#/pr/acme/api/317/merge")).toEqual({ kind: "pr", pr: "acme/api#317", screen: "merge" });
    expect(parseRoute("#/pr/acme/api/317/chat/merge")).toEqual({ kind: "pr", pr: "acme/api#317", screen: "chat", chat: "merge" });
    expect(parseRoute("#/pr/acme/api/317/nope")).toEqual({ kind: "pr", pr: "acme/api#317" });
    expect(parseRoute("#/pr/acme/api/0")).toEqual(HOME);
    expect(parseRoute("#/pr/../api/1")).toEqual(HOME);
    expect(parseRoute("#/whatever")).toEqual(HOME);
    for (const hash of ["#/home", "#/mine", "#/activity", "#/settings", "#/pair", "#/pr/acme/api/317",
                        "#/pr/acme/api/317/review", "#/pr/acme/web-app/488/fixci", "#/pr/acme/api/317/chat/review"]) {
      expect(routeHash(parseRoute(hash))).toBe(hash);
    }
  });

  it("reconoce el link de emparejamiento del QR", () => {
    const route = parseRoute("#pair?v=1&r=relay.example.com", "https://relay.example.com");
    expect(route).toEqual({ kind: "pairLink", link: "https://relay.example.com/#pair?v=1&r=relay.example.com" });
  });

  it("Back sin historial va a la ruta padre", () => {
    const mine = (pr: string) => pr === "acme/api#322";
    expect(parentRoute({ kind: "pr", pr: "acme/api#322", screen: "merge" }, mine)).toEqual({ kind: "tab", tab: "mine" });
    expect(parentRoute({ kind: "pr", pr: "acme/api#317", screen: "review" }, mine)).toEqual(HOME);
    expect(parentRoute({ kind: "pr", pr: "acme/api#317", screen: "chat", chat: "review" }, mine))
      .toEqual({ kind: "pr", pr: "acme/api#317", screen: "review" });
    expect(parentRoute({ kind: "pr", pr: "acme/a#1", screen: "diff" }, mine)).toEqual({ kind: "pr", pr: "acme/a#1", screen: "respond" });
  });

  it("apila con pushState y vuelve con back", () => {
    const entries: { state: unknown; url: string }[] = [{ state: null, url: "#/home" }];
    let index = 0;
    const location = { get hash() { return entries[index]!.url; }, host: "relay.example.com" };
    const history = {
      get state() { return entries[index]!.state; },
      pushState(state: unknown, _: string, url?: string) { entries.splice(index + 1); entries.push({ state, url: url! }); index++; },
      replaceState(state: unknown, _: string, url?: string) { entries[index] = { state, url: url! }; },
      back() { index--; router.sync(); },
    };
    const router = new Router(history, location);
    router.go({ kind: "pr", pr: "acme/api#317", screen: "review" });
    expect(location.hash).toBe("#/pr/acme/api/317/review");
    expect(router.depth).toBe(1);
    router.back();
    expect(router.route.value).toEqual(HOME);
    // Abierta desde una notificación: sin historial, Back reemplaza por el padre.
    router.replace({ kind: "pr", pr: "acme/api#317", screen: "chat", chat: "review" });
    router.back();
    expect(router.route.value).toEqual({ kind: "pr", pr: "acme/api#317", screen: "review" });
    router.tab("settings");
    expect(location.hash).toBe("#/settings");
    expect(router.depth).toBe(0);
  });
});

describe("install gating", () => {
  const media = (matches: boolean) => () => ({ matches });

  it("instalada: display-mode standalone o navigator.standalone", () => {
    expect(isStandalone({ matchMedia: media(true), mode: "production" })).toBe(true);
    expect(isStandalone({ matchMedia: media(false), navigator: { standalone: true }, mode: "production" })).toBe(true);
    expect(isStandalone({ matchMedia: media(false), navigator: {}, mode: "production" })).toBe(false);
  });

  it("?standalone=1 solo fuera de producción", () => {
    const location = { search: "?standalone=1" };
    expect(isStandalone({ matchMedia: media(false), location, mode: "production" })).toBe(false);
    expect(isStandalone({ matchMedia: media(false), location, mode: "e2e" })).toBe(true);
    expect(isStandalone({ matchMedia: media(false), location: { search: "" }, mode: "development" })).toBe(false);
  });

  it("plataforma y modelo del user agent", () => {
    const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15";
    const android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/140 Mobile";
    const mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15";
    expect(platformOf(iphone)).toBe("ios");
    expect(platformOf(android)).toBe("android");
    expect(platformOf(mac)).toBe("other");
    expect(platformOf(mac, 5)).toBe("ios");
    expect(deviceModel(iphone)).toBe("iPhone");
    expect(deviceModel(android)).toBe("Android");
    expect(deviceModel(mac)).toBe("Mac");
    expect(deviceModel("Mozilla/5.0 (X11; Linux x86_64)")).toBe("Device");
    expect(defaultDeviceName(iphone)).toBe("iPhone");
    expect(defaultDeviceName(android)).toBe("Android");
  });
});

describe("ActionRunner", () => {
  it("pide Face ID solo para los comandos gated y muestra :faceid mientras tanto", async () => {
    const app = makeApp();
    await app.runner.run({ refresh: {} });
    expect(app.signed).toHaveLength(0);
    const pending = app.runner.run({ merge: { pr: "acme/api#322", method: "squash", confirmed: true, expectedHeadOid: "abc" } });
    await pending;
    expect(app.signed).toHaveLength(1);
    expect(app.transport.sent.at(-1)).toMatchObject({ presence: true });
    expect(app.runner.faceIdPending.value).toBe(false);
  });

  it("Face ID cancelado no manda nada y no es un error para mostrar", async () => {
    const app = makeApp();
    app.presence.mode = "cancel";
    const error = await app.runner.run({ respondPush: { pr: "acme/a#1", confirmed: true, wait: false } }).catch((e) => e);
    expect(error).toBeInstanceOf(ActionFailure);
    expect((error as ActionFailure).error).toEqual({ kind: "cancelled" });
    expect(app.transport.sent).toHaveLength(0);
  });

  it("sin passkey: el mensaje de la Mac sin mandar nada", async () => {
    const app = makeApp();
    app.presence.mode = "none";
    const error = (await app.runner.run({ merge: { pr: "acme/api#322", confirmed: true, expectedHeadOid: "x" } })
      .catch((e) => e)) as ActionFailure;
    expect(error.error).toEqual({ kind: "failed", message: "Face ID isn't set up on this device. Pair it again." });
    expect(app.transport.sent).toHaveLength(0);
  });

  it("Mac sin exigir Face ID: no se firma", async () => {
    const app = makeApp();
    app.transport.setPresencePolicy({ requirePresence: false, gated: [] });
    await app.runner.run({ merge: { pr: "acme/api#322", confirmed: true, expectedHeadOid: "x" } });
    expect(app.signed).toHaveLength(0);
  });

  it("confirmationRequired y errores de la Mac", async () => {
    const app = makeApp();
    app.transport.respond("chatUndo", () => new CommandError({ code: "confirmationRequired", message: "Discard edits?" }));
    const error = (await app.runner.run({ chatUndo: { pr: "acme/a#1", confirmed: false } }).catch((e) => e)) as ActionFailure;
    expect(error.error).toEqual({ kind: "needsConfirmation", message: "Discard edits?" });
    app.transport.setState({ kind: "macOffline", since: null });
    const offline = (await app.runner.run({ refresh: {} }).catch((e) => e)) as ActionFailure;
    expect(offline.error).toEqual({ kind: "failed", message: "Your Mac is offline." });
  });
});
