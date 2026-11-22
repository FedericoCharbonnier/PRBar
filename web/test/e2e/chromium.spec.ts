import type { BrowserContext, CDPSession, Page } from "@playwright/test";
import { appState, expect, pair, PR, test, TITLES } from "./fixtures";
import { TestSubscription } from "./harness";

// Chromium con un autenticador WebAuthn virtual (CDP) contra el relay de verdad y la Mac simulada: emparejar con
// passkey, la lista, approve/merge/Fix CI con "Face ID", apagar el requisito de Face ID, un push que llega cifrado al
// servicio falso y que el service worker muestra, y revocar desde la Mac.

test.describe.configure({ mode: "serial" });

let context: BrowserContext;
let page: Page;
let cdp: CDPSession;
let authenticatorId: string;

test.beforeAll(async ({ browser, world }) => {
  context = await browser.newContext({ viewport: { width: 393, height: 852 } });
  await context.grantPermissions(["notifications"], { origin: world.relay.origin });
  // Face ID tiene que pedirse dentro del gesto del usuario (Safari no lo muestra después de un `await`). Cada listener
  // se envuelve para saber si `credentials.get` se llama mientras corre (sincrónico con el evento) o después, en un
  // microtask o más tarde; se anota el tipo de evento o `null`.
  await context.addInitScript(() => {
    const w = window as unknown as { __gets: (string | null)[]; __creates: (string | null)[] };
    w.__gets = [];
    w.__creates = [];
    const running: string[] = [];
    const wrappers = new WeakMap<object, EventListener>();
    const wrap = (listener: EventListenerOrEventListenerObject): EventListener => {
      let wrapped = wrappers.get(listener);
      if (!wrapped) {
        wrapped = function (this: unknown, event: Event) {
          running.push(event.type);
          try {
            return typeof listener === "function" ? listener.call(this, event) : listener.handleEvent(event);
          } finally {
            running.pop();
          }
        };
        wrappers.set(listener, wrapped);
      }
      return wrapped;
    };
    const add = EventTarget.prototype.addEventListener;
    const remove = EventTarget.prototype.removeEventListener;
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      return add.call(this, type, listener ? wrap(listener) : listener, options);
    };
    EventTarget.prototype.removeEventListener = function (type, listener, options) {
      return remove.call(this, type, listener ? wrap(listener) : listener, options);
    };
    const create = navigator.credentials.create.bind(navigator.credentials);
    navigator.credentials.create = (options) => {
      w.__creates.push(running[running.length - 1] ?? null);
      return create(options);
    };
    const get = navigator.credentials.get.bind(navigator.credentials);
    navigator.credentials.get = (options) => {
      w.__gets.push(running[running.length - 1] ?? null);
      return get(options);
    };
  });
  page = await context.newPage();
  page.on("console", (m) => {
    if (m.type() === "error") console.log(`[page error] ${m.text()}`);
  });
  cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  ({ authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
               isUserVerified: true, automaticPresenceSimulation: true },
  }));
});

test.afterAll(async () => {
  await context?.close();
});

/** Las firmas que hizo la passkey: el contador del autenticador virtual sube con cada `credentials.get`. */
async function signatures(): Promise<number> {
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  expect(credentials).toHaveLength(1);
  return credentials[0]!.signCount;
}

/** El evento en curso en cada llamada a `credentials.get` (ver el init script). */
function gestures(): Promise<(string | null)[]> {
  return page.evaluate(() => (window as unknown as { __gets: (string | null)[] }).__gets);
}

/** Cada Face ID pedido hasta ahora se pidió dentro del listener del toque (`click`, o `change` de un switch). */
async function expectFaceIdInGesture(count: number): Promise<void> {
  const events = await gestures();
  expect(events).toHaveLength(count);
  for (const event of events) expect(["click", "change"]).toContain(event);
}

function row(title: string) {
  return page.getByRole("button", { name: new RegExp(`^${title}, `) });
}

async function goHome(tab: "To Review" | "My PRs" = "To Review"): Promise<void> {
  await page.evaluate((hash) => (location.hash = hash), tab === "To Review" ? "#/home" : "#/mine");
  await expect(page.getByRole("heading", { name: tab, level: 1 })).toBeVisible();
}

test("pairs with a passkey and shows the Mac's PRs", async ({ world }) => {
  await pair(page, world);
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  expect(credentials).toHaveLength(1);
  expect(credentials[0]!.rpId).toBe("localhost");
  // La passkey se creó en el toque de "Scan QR on your Mac".
  expect(await page.evaluate(() => (window as unknown as { __creates: (string | null)[] }).__creates)).toEqual(["click"]);
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-link", "online");
  await expect.poll(async () => (await appState(page)).prs.sort()).toEqual([PR.review, PR.merge, PR.ci].sort());
  await expect(row(TITLES.review)).toBeVisible();
  await page.getByRole("tab", { name: "My PRs" }).click();
  await expect(row(TITLES.merge)).toBeVisible();
  await expect(row(TITLES.ci)).toBeVisible();
});

test("approves a review with Face ID", async ({ world }) => {
  await goHome();
  const before = await signatures();
  await row(TITLES.review).click();
  await expect(page.getByRole("heading", { name: "Expired refresh tokens are retried forever" })).toBeVisible();
  await page.getByRole("button", { name: /^Review decision: / }).click();
  await page.getByRole("menuitemradio", { name: "Approve" }).click();
  await page.getByRole("button", { name: "Post review, requires Face ID" }).click();
  await expect(page.getByRole("heading", { name: "Review posted" })).toBeVisible();
  expect(await signatures()).toBe(before + 1);
  await expectFaceIdInGesture(1);
  const state = await world.mac.state();
  expect(state.approved).toEqual([PR.review]);
  expect(state.calls).toContain(`reviewPublish ${PR.review} APPROVE`);
});

test("merges with Face ID", async ({ world }) => {
  await goHome("My PRs");
  const before = await signatures();
  await row(TITLES.merge).click();
  const merge = page.getByRole("button", { name: "Merge, requires Face ID" });
  await expect(merge).toBeEnabled();
  await merge.click();
  await expect(page.getByRole("heading", { name: "Merged" })).toBeVisible();
  expect(await signatures()).toBe(before + 1);
  await expectFaceIdInGesture(2);
  const state = await world.mac.state();
  expect(state.merged).toEqual([PR.merge]);
  await page.getByRole("button", { name: "Done" }).click();
  await expect.poll(async () => (await appState(page)).prs).not.toContain(PR.merge);
});

test("fixes CI and pushes with Face ID", async ({ world }) => {
  await goHome("My PRs");
  const before = await signatures();
  await row(TITLES.ci).click();
  await expect(page.getByRole("heading", { name: "Fix CI" })).toBeVisible();
  await page.getByRole("button", { name: "Fix CI with Claude" }).click();
  await expect(page.getByText("test (ubuntu-latest)")).toBeVisible();
  const push = page.getByRole("button", { name: "Push, requires Face ID" });
  await expect(push).toBeEnabled();
  expect(await signatures()).toBe(before);
  await push.click();
  await expect.poll(async () => (await world.mac.state()).pushed).toEqual([PR.ci]);
  expect(await signatures()).toBe(before + 1);
  await expectFaceIdInGesture(3);
  expect((await world.mac.state()).calls).toContain(`ciFix ${PR.ci}`);
});

test("turning off the Face ID requirement needs Face ID", async ({ world }) => {
  await page.evaluate(() => (location.hash = "#/settings"));
  const toggle = page.getByRole("switch", { name: "Require Face ID for merge, push, approve and tests" });
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  await expect(toggle).toBeEnabled();
  const before = await signatures();

  // Sin la verificación del usuario la passkey no firma: no se manda nada y sigue prendido.
  await cdp.send("WebAuthn.setUserVerified", { authenticatorId, isUserVerified: false });
  await toggle.click();
  await expect(toggle).toBeEnabled();
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  expect((await world.mac.state()).calls.filter((c) => c.startsWith("remoteSetPresenceRequirement"))).toEqual([]);
  expect((await world.mac.devices())[0]?.["requirePresence"]).toBe(true);

  await cdp.send("WebAuthn.setUserVerified", { authenticatorId, isUserVerified: true });
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-checked", "false");
  expect(await signatures()).toBe(before + 1);
  // El intento sin verificación también se pidió en el click.
  await expectFaceIdInGesture(5);
  expect((await world.mac.state()).calls).toContain("remoteSetPresenceRequirement false");
  expect((await world.mac.devices())[0]?.["requirePresence"]).toBe(false);

  // Prenderlo de nuevo no pide Face ID.
  const signed = await signatures();
  await expect(toggle).toBeEnabled();
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-checked", "true");
  expect(await signatures()).toBe(signed);
  expect((await world.mac.devices())[0]?.["requirePresence"]).toBe(true);
});

test("a push from the Mac reaches the push service encrypted and the service worker shows it", async ({ world }) => {
  const { mac, capture, relay } = world;
  // El relay manda al servicio de push falso (WEBPUSH_TEST_ENDPOINT) con claves de esta prueba.
  const subscription = new TestSubscription(`${capture.prefix}device`);
  await page.evaluate((sub) => {
    (window as unknown as { __prbar: { registerWebPush(s: unknown): void } }).__prbar.registerWebPush(sub);
  }, subscription.json);
  // El relay guarda la suscripción al recibir el marco: se reintenta hasta que la Mac vea pushes entregados.
  const count = capture.pushes.length;
  await expect.poll(async () => {
    await mac.request("notify readyToMerge", "push");
    return capture.pushes.length;
  }, { timeout: 20_000 }).toBeGreaterThan(count);
  const delivered = capture.pushes[capture.pushes.length - 1]!;
  expect(delivered.path).toBe("/push/device");
  expect(delivered.headers["content-encoding"]).toBe("aes128gcm");
  expect(delivered.headers["authorization"]).toMatch(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+$/);
  const payload = JSON.parse(subscription.decrypt(delivered.body).toString("utf8")) as Record<string, unknown>;
  expect(payload["v"]).toBe(1);
  expect(typeof payload["e"]).toBe("string");
  // Lo que ve el relay es el sobre HPKE: ni el título ni el PR aparecen en claro.
  expect(JSON.stringify(payload)).not.toContain("Ready to Merge");

  // El tramo del service worker: el mismo payload entregado como push de verdad (CDP), que lo abre con la clave del
  // dispositivo y muestra la notificación descifrada.
  await cdp.send("ServiceWorker.enable");
  const registrationId = await new Promise<string>((resolve) => {
    cdp.on("ServiceWorker.workerRegistrationUpdated", ({ registrations }) => {
      const mine = registrations.find((r) => r.scopeURL === `${relay.origin}/` && !r.isDeleted);
      if (mine) resolve(mine.registrationId);
    });
  });
  await cdp.send("ServiceWorker.deliverPushMessage", { origin: relay.origin, registrationId,
                                                       data: JSON.stringify(payload) });
  await expect.poll(() => page.evaluate(async () => {
    const registration = await navigator.serviceWorker.ready;
    return (await registration.getNotifications()).map((n) => ({ title: n.title, body: n.body, tag: n.tag }));
  })).toContainEqual({ title: "Ready to Merge", body: "api#322 · Make payment retries idempotent", tag: expect.any(String) });
});

test("revoking on the Mac sends the phone back to pairing", async ({ world }) => {
  await goHome();
  await world.mac.request("revoke", "revoked");
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "welcome");
  await expect(page.getByText("This iPhone was removed from Fixture Mac.")).toBeVisible();
  expect((await appState(page)).link).toBe("unpaired");
  // Las claves se borraron: al recargar sigue en pair:welcome.
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-ready", "true");
  expect((await appState(page)).route.kind).toBe("pair");
});
