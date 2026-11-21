import type { Incompatibility, RemoteHello } from "./appFrames";

// Versiones del protocolo (spec P.6 y W.8). `COMMAND_PROTOCOL` es el `CommandProtocol.version` de la Mac que este
// teléfono habla; la Mac acepta un teléfono entre su `minimumRemoteVersion` y su versión.

export const COMMAND_PROTOCOL = 8;
export const MINIMUM_REMOTE_VERSION = 8;
export { REMOTE_PROTOCOL } from "./appFrames";

/** El texto que muestra la UI para cada incompatibilidad (RemoteError.incompatible de Swift). */
export const INCOMPATIBLE_MESSAGE: Record<Incompatibility, string> = {
  updateMac: "Update PRBar on your Mac.",
  updateIPhone: "Update PRBar on this iPhone.",
};

/** Lo que dice el `hello` de la Mac: `null` si se puede seguir. Además de lo que diga la Mac, una Mac con un
 *  protocolo más viejo que el mínimo de este teléfono (una Mac sin actualizar que no sabe decirlo) es `updateMac`. */
export function helloIncompatibility(hello: RemoteHello): Incompatibility | null {
  if (hello.incompatible) return hello.incompatible;
  if (hello.commandProtocol < MINIMUM_REMOTE_VERSION) return "updateMac";
  return null;
}
