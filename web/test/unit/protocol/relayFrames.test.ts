import { describe, expect, it } from "vitest";
import { toHex } from "../../../src/crypto/bytes";
import { DecodeError } from "../../../src/protocol/json";
import { decodeRelayMessage, encodeRelayMessage } from "../../../src/protocol/relayFrames";
import { fixture, type FramesFixture } from "../fixtures";

const frames = fixture<FramesFixture>("frames.json");

describe("relay frames (frames.json)", () => {
  for (const [index, sample] of frames.relay.entries()) {
    it(`#${index} ${sample.type}: decode → encode da los mismos bytes`, () => {
      const message = decodeRelayMessage(sample.text);
      expect(message.t).toBe(sample.type);
      expect(encodeRelayMessage(message)).toBe(sample.text);
    });
  }

  it("decodifica los binarios como bytes", () => {
    const send = decodeRelayMessage(frames.relay.find((f) => f.type === "send")!.text);
    expect(send.t === "send" && toHex(send.b)).toBe("010203fafbfc");
    const webpush = decodeRelayMessage(frames.relay.find((f) => f.type === "webpush")!.text);
    expect(webpush.t === "webpush" && [webpush.p256dh.length, webpush.auth.length]).toEqual([65, 16]);
  });

  it("un tipo desconocido no rompe y se reescribe igual", () => {
    expect(decodeRelayMessage(`{"t":"future","x":1}`)).toEqual({ t: "unknown", type: "future" });
    expect(encodeRelayMessage({ t: "unknown", type: "future" })).toBe(`{"t":"future"}`);
  });

  it("rechaza JSON roto, campos faltantes y base64 no canónico", () => {
    expect(() => decodeRelayMessage("{")).toThrow(DecodeError);
    expect(() => decodeRelayMessage(`{"t":"ready","mac":"online"}`)).toThrow(DecodeError);
    expect(() => decodeRelayMessage(`{"t":"recv","from":"mac","sid":"00","b":"AQ=="}`)).toThrow(DecodeError);
    expect(() => decodeRelayMessage(`{"t":"recv","from":"mac","sid":"00","b":"A+/"}`)).toThrow(DecodeError);
  });
});
