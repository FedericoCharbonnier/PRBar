import { expect } from "vitest";
import { fromHex, toHex } from "../../../src/crypto/bytes";
import { NoiseHandshake, type NoisePattern, type NoiseTransport } from "../../../src/crypto/noise";

// Formato de los vectores de cacophony/snow (el mismo que usa NoiseTests.swift). Los vectores cruzados de la Mac
// (`test/fixtures/noise-*.json`) se pueden correr con este mismo runner si siguen el formato.
export interface NoiseVector {
  source?: string;
  protocol_name: string;
  init_prologue: string;
  init_psks?: string[];
  init_static: string;
  init_ephemeral: string;
  init_remote_static?: string;
  resp_prologue: string;
  resp_psks?: string[];
  resp_static: string;
  resp_ephemeral: string;
  resp_remote_static?: string;
  handshake_hash?: string;
  messages: { payload: string; ciphertext: string }[];
}

/** Handshake + transporte, alternando iniciador y respondedor como el vector; compara cada mensaje byte a byte. */
export function runNoiseVector(v: NoiseVector): void {
  const pattern: NoisePattern = v.protocol_name.includes("_KK_") ? "kk" : "ikpsk2";
  const label = `${v.source ?? "?"} ${v.protocol_name}`;
  const initiator = new NoiseHandshake({
    pattern, initiator: true, prologue: fromHex(v.init_prologue), localStatic: fromHex(v.init_static),
    remoteStatic: v.init_remote_static ? fromHex(v.init_remote_static) : null,
    psk: v.init_psks?.[0] ? fromHex(v.init_psks[0]) : null, fixedEphemeral: fromHex(v.init_ephemeral),
  });
  const responder = new NoiseHandshake({
    pattern, initiator: false, prologue: fromHex(v.resp_prologue), localStatic: fromHex(v.resp_static),
    remoteStatic: v.resp_remote_static ? fromHex(v.resp_remote_static) : null,
    psk: v.resp_psks?.[0] ? fromHex(v.resp_psks[0]) : null, fixedEphemeral: fromHex(v.resp_ephemeral),
  });
  let transports: { i: NoiseTransport; r: NoiseTransport } | undefined;
  v.messages.forEach((m, index) => {
    const payload = fromHex(m.payload);
    const fromInitiator = index % 2 === 0;
    if (index < 2) {
      const written = fromInitiator ? initiator.writeMessage(payload) : responder.writeMessage(payload);
      expect(toHex(written), `${label}: mensaje ${index}`).toBe(m.ciphertext);
      const read = fromInitiator ? responder.readMessage(written) : initiator.readMessage(written);
      expect(toHex(read), `${label}: payload ${index}`).toBe(m.payload);
      if (index === 1) {
        expect(initiator.isComplete && responder.isComplete).toBe(true);
        expect(toHex(initiator.handshakeHash)).toBe(toHex(responder.handshakeHash));
        if (v.handshake_hash) expect(toHex(initiator.handshakeHash)).toBe(v.handshake_hash);
        transports = { i: initiator.split(), r: responder.split() };
      }
    } else {
      if (!transports) throw new Error(`${label}: sin transporte`);
      const [send, receive] = fromInitiator ? [transports.i.send, transports.r.receive] : [transports.r.send, transports.i.receive];
      const written = send.encrypt(payload);
      expect(toHex(written), `${label}: transporte ${index}`).toBe(m.ciphertext);
      expect(toHex(receive.decrypt(written))).toBe(m.payload);
    }
  });
}
