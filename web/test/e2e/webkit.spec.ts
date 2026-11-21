import type { BrowserContext, Page } from "@playwright/test";
import { appState, expect, pair, PR, test, TITLES } from "./fixtures";

// WebKit (el motor de Safari) contra el relay de verdad y la Mac simulada: emparejar y ver la lista. Playwright no
// tiene autenticador WebAuthn virtual en WebKit: la passkey no se crea y el emparejamiento sigue sin ella (W.4.6); la
// Mac deja ese dispositivo con Face ID obligatorio y sin credencial, así que los comandos gated quedan bloqueados.

test.describe.configure({ mode: "serial" });

let context: BrowserContext;
let page: Page;

test.beforeAll(async ({ browser }) => {
  context = await browser.newContext({ viewport: { width: 393, height: 852 } });
  page = await context.newPage();
  page.on("console", (m) => {
    if (m.type() === "error") console.log(`[page error] ${m.text()}`);
  });
});

test.afterAll(async () => {
  await context?.close();
});

test("pairs without a passkey and shows the Mac's PRs", async ({ world }) => {
  await pair(page, world);
  const devices = await world.mac.devices();
  expect(devices).toHaveLength(1);
  expect(devices[0]?.["requirePresence"]).toBe(true);
  await page.getByRole("button", { name: /^(Continue|Not Now)$/ }).click();
  await expect(page.locator("html")).toHaveAttribute("data-link", "online");
  await expect.poll(async () => (await appState(page)).prs.sort()).toEqual([PR.review, PR.merge, PR.ci].sort());
  await expect(page.getByRole("button", { name: new RegExp(`^${TITLES.review}, `) })).toBeVisible();
  await page.getByRole("tab", { name: "My PRs" }).click();
  await expect(page.getByRole("button", { name: new RegExp(`^${TITLES.merge}, `) })).toBeVisible();
  await expect(page.getByRole("button", { name: new RegExp(`^${TITLES.ci}, `) })).toBeVisible();
});

test("without a passkey a gated command says so and sends nothing", async ({ world }) => {
  await page.getByRole("button", { name: new RegExp(`^${TITLES.merge}, `) }).click();
  const merge = page.getByRole("button", { name: "Merge, requires Face ID" });
  await expect(merge).toBeEnabled();
  await merge.click();
  await expect(page.getByText("Face ID isn't set up on this device. Pair it again.")).toBeVisible();
  expect((await world.mac.state()).merged).toEqual([]);
});
