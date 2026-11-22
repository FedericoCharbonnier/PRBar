import { ActionRunner } from "../../../src/app/actions";
import type { AppContext, ConfirmRequest, UI } from "../../../src/app/context";
import type { Route } from "../../../src/app/router";
import { AppStore } from "../../../src/app/store";
import type { MenuItem } from "../../../src/ui/components";
import { FakeTransport } from "../../../src/transport/FakeTransport";
import type { LinkState } from "../../../src/transport/Transport";
import type { Authorize, Clock } from "../../../src/transport/types";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AppFixtureFile } from "../fixtures";

// Un contexto de app sobre FakeTransport con los JSON de la Mac (`app.json`): navegación, avisos y Face ID de mentira.

export const NOW = Date.parse("2026-11-20T12:50:00Z");

export class TestClock implements Clock {
  ms = NOW;
  now(): number {
    return this.ms;
  }
  setTimeout(fn: () => void, ms: number): unknown {
    return globalThis.setTimeout(fn, ms);
  }
  clearTimeout(handle: unknown): void {
    globalThis.clearTimeout(handle as ReturnType<typeof setTimeout>);
  }
}

export class TestUI implements UI {
  alerts: string[] = [];
  confirms: ConfirmRequest[] = [];
  menus: { label: string; items: MenuItem[] }[] = [];
  opened: string[] = [];
  confirmAnswer = true;
  menuAnswer: string | null = null;

  alert(message: string): void {
    this.alerts.push(message);
  }
  async confirm(request: ConfirmRequest): Promise<boolean> {
    this.confirms.push(request);
    return this.confirmAnswer;
  }
  async menu<T extends string>(label: string, items: MenuItem<T>[]): Promise<T | null> {
    this.menus.push({ label, items });
    return this.menuAnswer as T | null;
  }
  openURL(url: string): void {
    this.opened.push(url);
  }
}

export class TestNav {
  routes: Route[] = [];
  backs = 0;
  go(route: Route): void {
    this.routes.push(route);
  }
  replace(route: Route): void {
    this.routes.push(route);
  }
  back(): void {
    this.backs++;
  }
  get last(): Route | undefined {
    return this.routes.at(-1);
  }
}

export interface TestApp extends AppContext {
  transport: FakeTransport;
  ui: TestUI;
  nav: TestNav;
  clock: TestClock;
  /** Desafíos que firmó la passkey de mentira. */
  signed: Uint8Array[];
  /** Lo que hace la passkey: firmar (por defecto), cancelar o fallar. */
  presence: { mode: "sign" | "cancel" | "fail" | "none" };
}

/** `app.json` por ruta (con happy-dom, `URL` no es la de Node y `readFileSync(new URL(…))` falla). */
export function appFixture(): AppFixtureFile {
  const path = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures/app.json");
  return JSON.parse(readFileSync(path, "utf8")) as AppFixtureFile;
}

export function makeApp(options: { state?: LinkState; attach?: boolean } = {}): TestApp {
  const transport = new FakeTransport(appFixture(), options.state ?? { kind: "online" });
  transport.macName = "Studio";
  const clock = new TestClock();
  const store = new AppStore({ transport, clock });
  const signed: Uint8Array[] = [];
  const presence: TestApp["presence"] = { mode: "sign" };
  const authorize: Authorize = async (challenge) => {
    if (presence.mode === "cancel") {
      const { PresenceCancelled } = await import("../../../src/presence/webauthn");
      throw new PresenceCancelled();
    }
    if (presence.mode === "fail") {
      const { PresenceUnavailable } = await import("../../../src/presence/webauthn");
      throw new PresenceUnavailable("Face ID is locked.");
    }
    signed.push(challenge);
    const b = new Uint8Array(1);
    return { credentialId: b, authenticatorData: b, clientDataJSON: b, signature: b };
  };
  const runner = new ActionRunner(() => transport, () => (presence.mode === "none" ? null : authorize));
  if (options.attach !== false) store.attach();
  return { store, runner, transport, ui: new TestUI(), nav: new TestNav(), clock, signed, presence,
           locale: { locale: "en-US", timeZone: "UTC" } };
}

export const flush = async (times = 5) => {
  for (let i = 0; i < times; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

export function sentNames(app: TestApp): string[] {
  return app.transport.sent.map((s) => Object.keys(s.command)[0]!);
}
