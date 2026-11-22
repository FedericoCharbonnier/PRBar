import { signal, type ReadonlySignal } from "@preact/signals";
import type { CommandEvent } from "../protocol/appFrames";
import { commandName, decodeResult, type AppCommand, type ResultOf } from "../protocol/commands";
import { DecodeError } from "../protocol/json";
import { NO_PASSKEY_MESSAGE, PresenceCancelled, PresenceUnavailable } from "../presence/webauthn";
import type { Transport } from "../transport/Transport";
import { CommandError, RemoteError, type Authorize } from "../transport/types";

// Manda los comandos de las pantallas (ActionRunner.swift): pide Face ID solo si el comando es gated y la Mac lo exige
// para este dispositivo, y convierte los errores en lo que muestran las pantallas. La passkey se pide en el mismo
// toque del botón (gesto del usuario, W.5): `run` se llama directo desde el callback.

export type ActionError =
  /** Face ID cancelado: no se mandó nada; la pantalla queda como estaba (sin aviso). */
  | { kind: "cancelled" }
  /** La Mac (o el enlace) dijo que no: el texto va tal cual. */
  | { kind: "failed"; message: string }
  /** La Mac pide confirmar primero (`confirmationRequired`): el texto es la pregunta. */
  | { kind: "needsConfirmation"; message: string };

export class ActionFailure extends Error {
  constructor(readonly error: ActionError) {
    super(error.kind === "cancelled" ? "cancelled" : error.message);
  }
}

export const UNREADABLE_MESSAGE = "PRBar on your Mac sent something this device can’t read.";

export function toActionError(error: unknown): ActionError {
  if (error instanceof ActionFailure) return error.error;
  if (error instanceof PresenceCancelled) return { kind: "cancelled" };
  if (error instanceof PresenceUnavailable) return { kind: "failed", message: error.message };
  if (error instanceof CommandError) {
    if (error.code === "confirmationRequired") return { kind: "needsConfirmation", message: error.message };
    return { kind: "failed", message: error.message };
  }
  if (error instanceof RemoteError) return { kind: "failed", message: error.message };
  if (error instanceof DecodeError) return { kind: "failed", message: UNREADABLE_MESSAGE };
  return { kind: "failed", message: error instanceof Error && error.message ? error.message : "Something went wrong." };
}

export interface RunOptions {
  onEvent?: (event: CommandEvent) => void;
}

export class ActionRunner {
  readonly #transport: () => Transport;
  readonly #authorize: () => Authorize | null;
  readonly #faceIdPending = signal(false);
  #running = 0;

  /** `authorize`: la passkey guardada (`null` si se emparejó sin passkey). */
  constructor(transport: () => Transport, authorize: () => Authorize | null) {
    this.#transport = transport;
    this.#authorize = authorize;
  }

  /** Esperando el aviso de Face ID (`review:faceid`, `merge:faceid`). */
  get faceIdPending(): ReadonlySignal<boolean> {
    return this.#faceIdPending;
  }

  /** Hay comandos en curso (no es momento de recargar la app para una versión nueva). */
  get busy(): boolean {
    return this.#running > 0;
  }

  /** `true` si este comando va a pedir Face ID. */
  needsPresence(command: AppCommand): boolean {
    return this.#transport().needsPresence(command);
  }

  /** Manda el comando y espera el resultado decodificado. Tira `ActionFailure`. */
  async run<C extends AppCommand>(command: C, options: RunOptions = {}): Promise<ResultOf<C>> {
    const transport = this.#transport();
    const needsPresence = transport.needsPresence(command);
    let authorize: Authorize | undefined;
    if (needsPresence) {
      const base = this.#authorize();
      if (!base) throw new ActionFailure({ kind: "failed", message: NO_PASSKEY_MESSAGE });
      authorize = async (challenge) => {
        this.#faceIdPending.value = true;
        try {
          return await base(challenge);
        } finally {
          this.#faceIdPending.value = false;
        }
      };
    }
    this.#running++;
    try {
      const pending = await transport.send(command, {
        ...(authorize ? { authorize } : {}),
        ...(options.onEvent ? { onEvent: options.onEvent } : {}),
      });
      const result = await pending.result;
      return decodeResult(commandName(command), result) as ResultOf<C>;
    } catch (error) {
      throw new ActionFailure(toActionError(error));
    } finally {
      this.#running--;
      this.#faceIdPending.value = false;
    }
  }
}
