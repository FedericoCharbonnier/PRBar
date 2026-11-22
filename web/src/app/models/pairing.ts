import { signal, type ReadonlySignal } from "@preact/signals";
import { PresenceCancelled } from "../../presence/webauthn";
import { PairingQRError, parsePairingURL, type PairingQR } from "../../protocol/pairingQR";
import type { PairingOptions, PairingOutcome } from "../../transport/Pairing";
import { RemoteError, type PresenceCredential } from "../../transport/types";
import type { NotificationPermission } from "../../ui/screens/types";

// pair:welcome → (passkey) → pair:scan / Paste code → pair:confirm → pair:sas → pair:paired (PairingModel.swift y
// spec W.4). La passkey se crea en el toque de "Pair" (gesto del usuario); sin ella el emparejamiento sigue y los
// comandos gated quedan bloqueados en la Mac. Nada se guarda hasta que la Mac confirma (un intento fallido no toca un
// emparejamiento anterior, L4), y un link nunca reemplaza un emparejamiento sin la pantalla de confirmación.

export const INVALID_QR_MESSAGE = "This isn't a PRBar pairing code. Scan the QR in PRBar › Settings › Pair iPhone on your Mac.";
export const EXPIRED_MESSAGE = "The pairing code expired. Show a new one on your Mac and scan it again.";
export const CANCELLED_MESSAGE = "Pairing was cancelled. Start again from PRBar on your Mac.";
export const MISMATCH_MESSAGE = "Pairing was cancelled because the codes didn't match.";
export const OTHER_SERVER_MESSAGE = "This code is for a different PRBar server.";
export const LOST_PAIRING_MESSAGE = "This device lost its pairing. Pair it again from your Mac.";
export const NO_PASSKEY_NOTICE = "Face ID couldn't be set up on this device. You can pair, but merge, push, approve and tests won't work until you pair again.";
export const CAMERA_DENIED_MESSAGE = "PRBar can't use the camera. Allow it in Settings, or paste the code.";
export const revokedMessage = (mac: string) => `This iPhone was removed from ${mac}.`;

export type PairingStep =
  | { kind: "welcome" }
  | { kind: "scanning"; paste: { value: string; error?: string | undefined } | null }
  | { kind: "confirm"; qr: PairingQR; replacing: string | null; busy: boolean }
  | { kind: "sas"; code: string; macName: string }
  | { kind: "paired"; macName: string; notifications: NotificationPermission; busy: boolean };

/** Lo que el modelo necesita de una sesión de emparejamiento (`PairingSession`). */
export interface PairingSessionLike {
  readonly sas: string;
  finish(): Promise<PairingOutcome>;
  cancel(): void;
}

export interface NotificationsAPI {
  permission(): NotificationPermission;
  request(): Promise<NotificationPermission>;
}

export interface PairingDeps {
  /** El host de la página (= el relay, W.4.6). */
  rpId: string;
  /** "iPhone", "Android", "Mac" o "Device". */
  model: string;
  defaultName: string;
  createPasskey(options: { rpId: string; userName: string }): Promise<PresenceCredential>;
  startPairing(options: PairingOptions): Promise<PairingSessionLike>;
  /** Guarda el emparejamiento (claves envueltas) y pide almacenamiento persistente. */
  save(outcome: PairingOutcome, deviceName: string): Promise<void>;
  /** La Mac con la que ya está emparejado (un link nuevo la reemplaza). */
  currentMac(): string | null;
  notifications: NotificationsAPI;
  /** Suscribe Web Push (después del permiso). */
  subscribePush(): Promise<void>;
  /** Se guardó: la app arma el transporte (sigue mostrando pair:paired hasta "Continue"). */
  onPaired(outcome: PairingOutcome, deviceName: string): void;
  /** "Continue" en pair:paired. */
  onDone(): void;
  /** Solo fuera de producción: relay local por `ws://` (las pruebas e2e). */
  allowInsecureRelay: boolean;
  /** El host de la página con el puerto (`location.host`). Con `requireSameHost`, un código de otro relay se rechaza:
   *  la passkey, el service worker y los datos de esta app son de este host, y el emparejamiento tiene que serlo. */
  pageHost: string;
  /** En producción, siempre; fuera de producción se permite otro host (relays de prueba). */
  requireSameHost: boolean;
}

export interface PairingModel {
  step: ReadonlySignal<PairingStep>;
  deviceName: ReadonlySignal<string>;
  notice: ReadonlySignal<string | null>;
  /** Mensaje en pair:scan (sin passkey, cámara negada, QR inválido). */
  scanError: ReadonlySignal<string | null>;
  busy: ReadonlySignal<boolean>;
  setDeviceName(name: string): void;
  setNotice(notice: string | null): void;
  pair(): Promise<void>;
  cancelScanning(): void;
  cameraFailed(): void;
  scanned(text: string): void;
  openPaste(): void;
  setPaste(value: string): void;
  submitPaste(): void;
  closePaste(): void;
  /** Un link de emparejamiento abierto desde afuera (la cámara del sistema, `#pair?…`). */
  openLink(link: string): void;
  confirm(): Promise<void>;
  cancelConfirm(): void;
  mismatch(): void;
  allowNotifications(): Promise<void>;
  done(): void;
}

export function createPairingModel(deps: PairingDeps): PairingModel {
  const step = signal<PairingStep>({ kind: "welcome" });
  const deviceName = signal(deps.defaultName);
  const notice = signal<string | null>(null);
  const scanError = signal<string | null>(null);
  const busy = signal(false);
  /** `undefined`: todavía no se intentó crear; `null`: se intentó y no hay passkey. */
  let presence: PresenceCredential | null | undefined;
  let session: PairingSessionLike | null = null;
  let attempt = 0;

  const fail = (message: string) => {
    session = null;
    busy.value = false;
    notice.value = message;
    step.value = { kind: "welcome" };
  };

  const name = () => deviceName.value.trim() || deps.defaultName;

  /** Crea la passkey (una vez por emparejamiento). Sin ella se sigue, con el aviso. */
  const ensurePasskey = async () => {
    if (presence !== undefined) return;
    try {
      presence = await deps.createPasskey({ rpId: deps.rpId, userName: `PRBar · ${name()}` });
      scanError.value = null;
    } catch (error) {
      presence = null;
      scanError.value = NO_PASSKEY_NOTICE;
      if (!(error instanceof PresenceCancelled)) console.warn("passkey", error);
    }
  };

  /** El código parseado, o el mensaje para mostrar (código inválido o de otro relay). */
  const parse = (text: string): PairingQR | string => {
    let qr: PairingQR;
    try {
      qr = parsePairingURL(text, { allowInsecure: deps.allowInsecureRelay });
    } catch (error) {
      if (!(error instanceof PairingQRError)) console.warn("pairing link", error);
      return INVALID_QR_MESSAGE;
    }
    if (deps.requireSameHost && qr.relayHost !== deps.pageHost) return OTHER_SERVER_MESSAGE;
    return qr;
  };

  const toConfirm = (qr: PairingQR) => {
    step.value = { kind: "confirm", qr, replacing: deps.currentMac(), busy: false };
  };

  const model: PairingModel = {
    step, deviceName, notice, scanError, busy,
    setDeviceName(value) {
      deviceName.value = value;
    },
    setNotice(value) {
      notice.value = value;
    },
    async pair() {
      if (busy.value || !deviceName.value.trim()) return;
      busy.value = true;
      notice.value = null;
      presence = undefined;
      // El toque de "Pair" es el gesto del usuario que WebAuthn necesita (W.4.6).
      await ensurePasskey();
      busy.value = false;
      step.value = { kind: "scanning", paste: null };
    },
    cancelScanning() {
      step.value = { kind: "welcome" };
    },
    cameraFailed() {
      if (step.value.kind === "scanning" && scanError.value === null) scanError.value = CAMERA_DENIED_MESSAGE;
    },
    scanned(text) {
      if (step.value.kind !== "scanning") return;
      const qr = parse(text);
      if (typeof qr === "string") {
        scanError.value = qr;
        return;
      }
      toConfirm(qr);
    },
    openPaste() {
      if (step.value.kind === "scanning") step.value = { kind: "scanning", paste: { value: "" } };
    },
    setPaste(value) {
      if (step.value.kind === "scanning") step.value = { kind: "scanning", paste: { value } };
    },
    submitPaste() {
      const current = step.value;
      if (current.kind !== "scanning" || !current.paste) return;
      const qr = parse(current.paste.value);
      if (typeof qr === "string") {
        step.value = { kind: "scanning", paste: { value: current.paste.value, error: qr } };
        return;
      }
      toConfirm(qr);
    },
    closePaste() {
      if (step.value.kind === "scanning") step.value = { kind: "scanning", paste: null };
    },
    openLink(link) {
      if (step.value.kind === "sas" || busy.value) return;
      const qr = parse(link);
      if (typeof qr === "string") {
        notice.value = qr;
        step.value = { kind: "welcome" };
        return;
      }
      notice.value = null;
      presence = undefined;
      toConfirm(qr);
    },
    async confirm() {
      const current = step.value;
      if (current.kind !== "confirm" || current.busy) return;
      step.value = { ...current, busy: true };
      busy.value = true;
      // Por un link de afuera todavía no hay passkey: este toque es el gesto.
      await ensurePasskey();
      const mine = ++attempt;
      let started: PairingSessionLike;
      try {
        started = await deps.startPairing({ qr: current.qr, deviceName: name(), model: deps.model,
                                            presence: presence ?? null, insecure: deps.allowInsecureRelay });
      } catch (error) {
        if (mine === attempt) fail(pairingErrorMessage(error));
        return;
      }
      if (mine !== attempt) {
        started.cancel();
        return;
      }
      session = started;
      busy.value = false;
      const macName = current.qr.macName;
      step.value = { kind: "sas", code: started.sas, macName };
      let outcome: PairingOutcome;
      try {
        outcome = await started.finish();
      } catch (error) {
        if (mine === attempt && session === started) fail(pairingErrorMessage(error));
        return;
      }
      if (mine !== attempt) return;
      try {
        await deps.save(outcome, name());
      } catch (error) {
        fail(error instanceof Error ? error.message : "The pairing couldn't be saved.");
        return;
      }
      session = null;
      scanError.value = null;
      step.value = { kind: "paired", macName: outcome.mac.macName, notifications: deps.notifications.permission(),
                     busy: false };
      deps.onPaired(outcome, name());
    },
    cancelConfirm() {
      attempt++;
      busy.value = false;
      step.value = { kind: "welcome" };
    },
    mismatch() {
      attempt++;
      const current = session;
      session = null;
      current?.cancel();
      fail(MISMATCH_MESSAGE);
    },
    async allowNotifications() {
      const current = step.value;
      if (current.kind !== "paired" || current.busy) return;
      step.value = { ...current, busy: true };
      let permission: NotificationPermission;
      try {
        permission = await deps.notifications.request();
      } catch {
        permission = "denied";
      }
      if (permission === "granted") {
        try {
          await deps.subscribePush();
        } catch (error) {
          console.warn("push", error);
        }
      }
      step.value = { ...current, notifications: permission, busy: false };
    },
    done() {
      step.value = { kind: "welcome" };
      notice.value = null;
      deps.onDone();
    },
  };
  return model;
}

export function pairingErrorMessage(error: unknown): string {
  if (error instanceof PairingQRError) return INVALID_QR_MESSAGE;
  if (error instanceof RemoteError) {
    if (error.code === "pairingExpired") return EXPIRED_MESSAGE;
    if (error.code === "pairingCancelled") return CANCELLED_MESSAGE;
    return error.message;
  }
  return error instanceof Error && error.message ? error.message : CANCELLED_MESSAGE;
}
