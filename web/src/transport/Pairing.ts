import { randomBytes, toHex, type Bytes } from "../crypto/bytes";
import { ed25519PublicKey, generateEd25519, generateX25519, x25519PublicKey } from "../crypto/curves";
import { NoiseHandshake, pairingPrologue, type NoiseTransport } from "../crypto/noise";
import { pairingSecrets } from "../crypto/relayAuth";
import { sasCode, sasDisplay } from "../crypto/sas";
import { decodePairingMessage, encodePairingMessage, type PairingResult } from "../protocol/appFrames";
import { parsePairingURL, type PairingQR } from "../protocol/pairingQR";
import { displayName } from "../protocol/text";
import { RelayLink, type WebSocketFactory } from "./RelayClient";
import {
  RemoteError, systemClock, type Clock, type DeviceKeys, type PairedMac, type PresenceCredential,
} from "./types";

// El emparejamiento del lado del teléfono (spec P.11 y W.4, la parte de emparejamiento de RemoteClient.swift):
// conecta como `pair` con la prueba del QR, manda el primer mensaje de Noise IKpsk2 con `{deviceName, model, claves
// públicas, passkey}`, lee la respuesta de la Mac, manda `confirm` y muestra el código de 6 dígitos. Después espera
// "Codes Match" en la Mac (`result`), contesta el acuse (M1) y devuelve lo que hay que guardar. No guarda nada: eso lo
// hace quien llama, recién con el resultado (un intento fallido no toca un emparejamiento anterior, L4).

export function generateDeviceKeys(): DeviceKeys {
  return { relay: generateEd25519(), noise: generateX25519(), push: generateX25519() };
}

export interface PairingOptions {
  /** El texto del QR (o pegado) o el QR ya parseado. */
  qr: string | PairingQR;
  /** El nombre que eligió el usuario ("iPhone" por defecto) y el modelo que se pueda saber. */
  deviceName: string;
  model: string;
  /** La passkey creada antes del handshake (W.4.6); `null` si no se pudo. */
  presence: PresenceCredential | null;
  /** Claves nuevas del teléfono (por defecto se generan). */
  keys?: DeviceKeys;
  webSocket?: WebSocketFactory;
  clock?: Clock;
  /** Relay local de los tests (`ws://`, IP literal). */
  insecure?: boolean;
  handshakeTimeoutMs?: number;
  /** Solo para los vectores de prueba. */
  sid?: string;
  fixedEphemeral?: Bytes;
}

/** Lo que el teléfono guarda cuando la Mac confirma. */
export interface PairingOutcome {
  mac: PairedMac;
  keys: DeviceKeys;
  presence: PresenceCredential | null;
}

/** La ranura de la Mac dura 5 min; esto es solo una red de seguridad. */
const RESULT_TIMEOUT_MS = 360_000;

export class PairingSession {
  readonly qr: PairingQR;
  readonly sid: string;
  /** `"123456"`. */
  sas = "";
  readonly #options: PairingOptions;
  readonly #clock: Clock;
  readonly #keys: DeviceKeys;
  readonly #link: RelayLink;
  #transport: NoiseTransport | null = null;
  #handshakeWaiter: ((reply: Bytes | RemoteError) => void) | null = null;
  #outcome: PairingResult | RemoteError | null = null;
  #resultWaiter: ((outcome: PairingResult | RemoteError) => void) | null = null;
  #closed = false;

  constructor(options: PairingOptions, qr: PairingQR) {
    this.#options = options;
    this.qr = qr;
    this.#clock = options.clock ?? systemClock;
    this.#keys = options.keys ?? generateDeviceKeys();
    this.sid = options.sid ?? toHex(randomBytes(8));
    const secrets = pairingSecrets(qr.secret);
    this.#link = new RelayLink({
      host: qr.relayHost, credential: { kind: "pairing", account: qr.accountId, pairing: qr.pairingId,
                                        authKey: secrets.authKey },
      ...(options.webSocket ? { webSocket: options.webSocket } : {}), clock: this.#clock,
      insecure: options.insecure ?? false,
    });
  }

  /** `"123 456"`. */
  get sasDisplay(): string {
    return sasDisplay(this.sas);
  }

  async start(): Promise<string> {
    const { qr } = this;
    try {
      await this.#link.connect();
    } catch {
      this.#closed = true;
      throw new RemoteError("pairingExpired");
    }
    this.#link.onMessage = (message) => {
      if (message.t === "recv" && message.from === "mac" && message.sid === this.sid) this.#received(message.b);
    };
    this.#link.onClose = () => this.#fail(new RemoteError("pairingCancelled"));
    try {
      const handshake = new NoiseHandshake({
        pattern: "ikpsk2", initiator: true, prologue: pairingPrologue(qr.accountId, qr.pairingId),
        localStatic: this.#keys.noise, remoteStatic: qr.macStatic, psk: pairingSecrets(qr.secret).psk,
        fixedEphemeral: this.#options.fixedEphemeral ?? null,
      });
      const join = encodePairingMessage({
        kind: "join",
        join: {
          deviceName: this.#options.deviceName, model: this.#options.model,
          relayKey: ed25519PublicKey(this.#keys.relay), push: x25519PublicKey(this.#keys.push),
          ...(this.#options.presence ? { presence: this.#options.presence } : {}),
        },
      });
      const reply = new Promise<Bytes | RemoteError>((resolve) => {
        this.#handshakeWaiter = resolve;
      });
      const timer = this.#clock.setTimeout(() => this.#handshakeWaiter?.(new RemoteError("pairingExpired")),
                                           this.#options.handshakeTimeoutMs ?? 15_000);
      this.#send(handshake.writeMessage(join));
      const answer = await reply;
      this.#clock.clearTimeout(timer);
      this.#handshakeWaiter = null;
      if (answer instanceof RemoteError) throw answer;
      handshake.readMessage(answer);
      const transport = handshake.split();
      this.#transport = transport;
      // El primer mensaje de transporte prueba que el teléfono tenía el psk (el secreto del QR).
      this.#send(transport.send.encrypt(encodePairingMessage({ kind: "confirm" })));
      this.sas = sasCode(handshake.handshakeHash);
      return this.sas;
    } catch (error) {
      this.cancel();
      throw error instanceof RemoteError ? error : new RemoteError("pairingExpired");
    }
  }

  /** Espera "Codes Match" en la Mac y devuelve lo que hay que guardar. */
  async finish(): Promise<PairingOutcome> {
    if (!this.#transport) throw new RemoteError("pairingCancelled");
    const outcome = this.#outcome ?? await new Promise<PairingResult | RemoteError>((resolve) => {
      const timer = this.#clock.setTimeout(() => this.#fail(new RemoteError("pairingExpired")), RESULT_TIMEOUT_MS);
      this.#resultWaiter = (value) => {
        this.#clock.clearTimeout(timer);
        resolve(value);
      };
    });
    this.#close();
    if (outcome instanceof RemoteError) throw outcome;
    const name = displayName(outcome.macName);
    return {
      mac: { accountId: this.qr.accountId, deviceId: outcome.deviceId, relayHost: this.qr.relayHost,
             macName: name || this.qr.macName, macStatic: this.qr.macStatic, macSeal: outcome.macSeal },
      keys: this.#keys,
      presence: this.#options.presence,
    };
  }

  /** "Codes Don't Match" o Cancel: suelta la ranura (la Mac ve que el teléfono se fue). */
  cancel(): void {
    this.#fail(new RemoteError("pairingCancelled"));
    this.#close();
  }

  #received(b: Bytes): void {
    if (this.#handshakeWaiter) {
      this.#handshakeWaiter(b);
      this.#handshakeWaiter = null;
      return;
    }
    let message;
    try {
      message = decodePairingMessage(this.#transport!.receive.decrypt(b));
    } catch {
      return this.#fail(new RemoteError("pairingCancelled"));
    }
    if (message.kind === "result" && this.#outcome === null) {
      if (message.result.macSeal.length !== 32 || message.result.deviceId.length === 0) {
        return this.#fail(new RemoteError("pairingCancelled"));
      }
      // Acuse: la Mac guarda el dispositivo recién cuando lo recibe (M1).
      try {
        this.#send(this.#transport!.send.encrypt(encodePairingMessage({ kind: "ack" })));
      } catch {
        return this.#fail(new RemoteError("pairingCancelled"));
      }
      this.#settle(message.result);
    } else {
      this.#fail(new RemoteError("pairingCancelled"));
    }
  }

  #send(b: Bytes): void {
    this.#link.send({ t: "send", to: "mac", sid: this.sid, b });
  }

  #fail(error: RemoteError): void {
    this.#handshakeWaiter?.(error);
    this.#handshakeWaiter = null;
    // Solo la primera palabra cuenta: el cierre de la ranura después del resultado no lo pisa.
    if (this.#outcome === null) this.#settle(error);
  }

  #settle(outcome: PairingResult | RemoteError): void {
    this.#outcome = outcome;
    this.#resultWaiter?.(outcome);
    this.#resultWaiter = null;
  }

  #close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#link.close();
  }
}

/** Se une a la ranura del QR, hace el handshake y devuelve la sesión con el código para comparar con la Mac. Tira
 *  `PairingQRError` si el texto no es un link de emparejamiento y `RemoteError` si no se pudo unir. */
export async function startPairing(options: PairingOptions): Promise<PairingSession> {
  const qr = typeof options.qr === "string" ? parsePairingURL(options.qr, { allowInsecure: options.insecure ?? false })
    : options.qr;
  const session = new PairingSession(options, qr);
  await session.start();
  return session;
}
