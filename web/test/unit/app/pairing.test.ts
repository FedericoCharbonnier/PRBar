import { describe, expect, it } from "vitest";
import {
  CANCELLED_MESSAGE, createPairingModel, EXPIRED_MESSAGE, INVALID_QR_MESSAGE, MISMATCH_MESSAGE, NO_PASSKEY_NOTICE,
  type PairingDeps, type PairingSessionLike,
} from "../../../src/app/models/pairing";
import { PresenceCancelled } from "../../../src/presence/webauthn";
import { pairingURL } from "../../../src/protocol/pairingQR";
import type { PairingOptions, PairingOutcome } from "../../../src/transport/Pairing";
import { RemoteError, type PresenceCredential } from "../../../src/transport/types";
import type { NotificationPermission } from "../../../src/ui/screens/types";
import { flush } from "./helpers";

const qr = {
  relayHost: "relay.example.com", accountId: "a".repeat(26), pairingId: "b".repeat(16), secret: new Uint8Array(32).fill(1),
  macStatic: new Uint8Array(32).fill(2), macName: "Studio",
};
const LINK = pairingURL(qr);
const credential: PresenceCredential = { credentialId: Uint8Array.of(1), publicKey: new Uint8Array(91), rpId: "relay.example.com" };

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function setup(options: { passkey?: "ok" | "cancel"; start?: () => Promise<PairingSessionLike>; current?: string | null } = {}) {
  const calls = { passkeys: 0, starts: [] as PairingOptions[], saved: [] as [PairingOutcome, string][], paired: 0, done: 0,
                  subscribed: 0, cancelled: 0 };
  const finish = deferred<PairingOutcome>();
  let permission: NotificationPermission = "default";
  const session: PairingSessionLike = {
    sas: "482913",
    finish: () => finish.promise,
    cancel: () => void calls.cancelled++,
  };
  const deps: PairingDeps = {
    rpId: "relay.example.com", model: "iPhone", defaultName: "iPhone",
    async createPasskey() {
      calls.passkeys++;
      if (options.passkey === "cancel") throw new PresenceCancelled();
      return credential;
    },
    startPairing: async (o) => {
      calls.starts.push(o);
      return options.start ? options.start() : session;
    },
    async save(outcome, name) {
      calls.saved.push([outcome, name]);
    },
    currentMac: () => options.current ?? null,
    notifications: {
      permission: () => permission,
      async request() {
        permission = "granted";
        return permission;
      },
    },
    async subscribePush() {
      calls.subscribed++;
    },
    onPaired: () => void calls.paired++,
    onDone: () => void calls.done++,
    allowInsecureRelay: false,
  };
  const outcome: PairingOutcome = {
    mac: { accountId: qr.accountId, deviceId: "dev", relayHost: qr.relayHost, macName: "Studio", macStatic: qr.macStatic,
           macSeal: new Uint8Array(32) },
    keys: { relay: new Uint8Array(32), noise: new Uint8Array(32), push: new Uint8Array(32) },
    presence: credential,
  };
  return { model: createPairingModel(deps), calls, finish, outcome };
}

describe("pairing", () => {
  it("Pair crea la passkey, escanea, confirma, muestra el código y guarda con la confirmación de la Mac", async () => {
    const { model, calls, finish, outcome } = setup();
    expect(model.step.value).toEqual({ kind: "welcome" });
    model.setDeviceName("Diego's iPhone");
    await model.pair();
    expect(calls.passkeys).toBe(1);
    expect(model.step.value).toEqual({ kind: "scanning", paste: null });
    model.scanned("not a link");
    expect(model.scanError.value).toBe(INVALID_QR_MESSAGE);
    model.scanned(LINK);
    expect(model.step.value).toMatchObject({ kind: "confirm", replacing: null, busy: false });
    const confirming = model.confirm();
    await flush();
    expect(calls.starts[0]).toMatchObject({ deviceName: "Diego's iPhone", model: "iPhone", presence: credential, insecure: false });
    expect(model.step.value).toEqual({ kind: "sas", code: "482913", macName: "Studio" });
    expect(calls.saved).toHaveLength(0);
    finish.resolve(outcome);
    await confirming;
    expect(calls.saved).toEqual([[outcome, "Diego's iPhone"]]);
    expect(calls.paired).toBe(1);
    expect(model.step.value).toEqual({ kind: "paired", macName: "Studio", notifications: "default", busy: false });
    await model.allowNotifications();
    expect(calls.subscribed).toBe(1);
    expect(model.step.value).toMatchObject({ notifications: "granted" });
    model.done();
    expect(calls.done).toBe(1);
  });

  it("sin passkey: el emparejamiento sigue con presence null y el aviso", async () => {
    const { model, calls } = setup({ passkey: "cancel" });
    await model.pair();
    expect(model.scanError.value).toBe(NO_PASSKEY_NOTICE);
    model.openPaste();
    model.setPaste("garbage");
    model.submitPaste();
    expect(model.step.value).toEqual({ kind: "scanning", paste: { value: "garbage", error: INVALID_QR_MESSAGE } });
    model.setPaste(LINK);
    model.submitPaste();
    void model.confirm();
    await flush();
    expect(calls.passkeys).toBe(1);
    expect(calls.starts[0]!.presence).toBeNull();
  });

  it("Codes Don't Match suelta la ranura y no guarda nada", async () => {
    const { model, calls, finish } = setup();
    await model.pair();
    model.scanned(LINK);
    const confirming = model.confirm();
    await flush();
    model.mismatch();
    finish.reject(new RemoteError("pairingCancelled"));
    await confirming;
    expect(calls.cancelled).toBe(1);
    expect(calls.saved).toHaveLength(0);
    expect(model.step.value).toEqual({ kind: "welcome" });
    expect(model.notice.value).toBe(MISMATCH_MESSAGE);
  });

  it("vencido o cancelado en la Mac", async () => {
    const expired = setup({ start: async () => { throw new RemoteError("pairingExpired"); } });
    await expired.model.pair();
    expired.model.scanned(LINK);
    await expired.model.confirm();
    expect(expired.model.notice.value).toBe(EXPIRED_MESSAGE);
    const cancelled = setup();
    await cancelled.model.pair();
    cancelled.model.scanned(LINK);
    const confirming = cancelled.model.confirm();
    await flush();
    cancelled.finish.reject(new RemoteError("pairingCancelled"));
    await confirming;
    expect(cancelled.model.notice.value).toBe(CANCELLED_MESSAGE);
    expect(cancelled.calls.saved).toHaveLength(0);
  });

  it("un link de afuera pasa por la confirmación y avisa qué reemplaza; la passkey se crea en ese toque", async () => {
    const { model, calls } = setup({ current: "Old Mac" });
    model.openLink(LINK);
    expect(model.step.value).toMatchObject({ kind: "confirm", replacing: "Old Mac" });
    expect(calls.passkeys).toBe(0);
    void model.confirm();
    await flush();
    expect(calls.passkeys).toBe(1);
    expect(calls.starts).toHaveLength(1);
    const bad = setup();
    bad.model.openLink("https://evil.example.com/#pair?v=1&r=relay.example.com");
    expect(bad.model.step.value).toEqual({ kind: "welcome" });
    expect(bad.model.notice.value).toBe(INVALID_QR_MESSAGE);
  });
});
