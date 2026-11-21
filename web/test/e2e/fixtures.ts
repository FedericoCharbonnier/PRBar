import { expect, test as base, type Page } from "@playwright/test";
import { FakeMac, PushCapture, Relay } from "./harness";

// Un mundo por archivo (worker): relay + push falso + Mac simulada. Las pruebas de un archivo corren en serie sobre la
// misma página (emparejar una vez y seguir).

export interface World {
  relay: Relay;
  capture: PushCapture;
  mac: FakeMac;
}

export const test = base.extend<object, { world: World }>({
  world: [async ({}, use) => {
    const capture = new PushCapture();
    await capture.start();
    const relay = new Relay();
    await relay.start(capture.prefix);
    const mac = new FakeMac();
    try {
      await mac.start(relay);
      await use({ relay, capture, mac });
    } finally {
      mac.stop();
      relay.stop();
      capture.stop();
    }
  }, { scope: "worker" }],
});

export { expect };

export interface AppState {
  ready: boolean;
  route: { kind: string; tab?: string; pr?: string; screen?: string };
  pairing: string;
  sas: string | null;
  notice: string | null;
  link: string;
  macName: string | null;
  prs: string[];
  alerts: string[];
}

export function appState(page: Page): Promise<AppState> {
  return page.evaluate(() => (window as unknown as { __prbar: { state(): AppState } }).__prbar.state());
}

/** Los PRs de `FixtureActions` (Sources/PRBarRemoteFixtures/FixtureActions.swift). */
export const PR = {
  review: "acme/api#317",
  merge: "acme/api#322",
  ci: "acme/web-app#488",
} as const;

export const TITLES = {
  review: "Refresh expired sessions without logging users out",
  merge: "Make payment retries idempotent",
  ci: "Move report jobs to the new queue",
} as const;

/** Empareja la página con la Mac simulada por "Paste code": compara el código de 6 dígitos de los dos lados y lo
 *  confirma en la Mac. Deja la página en pair:paired. */
export async function pair(page: Page, world: World): Promise<void> {
  const { relay, mac } = world;
  await page.goto(`${relay.origin}/?standalone=1`);
  await expect(page.locator("html")).toHaveAttribute("data-ready", "true");
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "welcome");
  await page.getByRole("button", { name: "Scan QR on your Mac" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "scanning");
  const pairing = await mac.request("pair", "pairing");
  const url = String(pairing["url"]);
  expect(url).toMatch(new RegExp(`^https://localhost:${relay.port}/#pair\\?`));
  const sasEvents = mac.events.length;
  await page.getByRole("button", { name: "Paste code" }).click();
  await page.getByRole("textbox", { name: "Pairing code" }).fill(url);
  await page.getByRole("button", { name: "Pair", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "confirm");
  await page.getByRole("button", { name: "Pair", exact: true }).click();
  const sas = await mac.waitFor("sas", undefined, 30_000, sasEvents);
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "sas");
  const shown = (await appState(page)).sas;
  expect(shown?.replace(/\s/g, "")).toBe(String(sas["code"]));
  await mac.request("confirm", "paired");
  await expect(page.locator("html")).toHaveAttribute("data-pairing", "paired");
  await expect(page.getByRole("heading", { name: "Paired with Fixture Mac" })).toBeVisible();
}
