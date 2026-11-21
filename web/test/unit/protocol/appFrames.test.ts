import { describe, expect, it } from "vitest";
import { fromHex, toHex, utf8 } from "../../../src/crypto/bytes";
import {
  chunkFrame, decodeFrame, decodePairingMessage, encodeFrame, encodePairingMessage, FrameAssembler, FramingError,
  MAX_CHUNK_DATA,
} from "../../../src/protocol/appFrames";
import { fixture, type FramesFixture } from "../fixtures";

const frames = fixture<FramesFixture>("frames.json");
const text = (data: Uint8Array) => new TextDecoder().decode(data);

describe("app frames (frames.json)", () => {
  for (const [index, sample] of frames.app.entries()) {
    it(`#${index} ${sample.type}: decode → encode da los mismos bytes`, () => {
      const frame = decodeFrame(utf8(sample.text));
      expect(frame.t).toBe(sample.type);
      expect(text(encodeFrame(frame))).toBe(sample.text);
    });
  }

  it("req: cmd en bytes, fechas en milisegundos y la prueba de presencia", () => {
    const req = decodeFrame(utf8(frames.app.find((f) => f.type === "req" && f.text.includes("presence"))!.text));
    if (req.t !== "req") throw new Error("not a req");
    expect(text(req.cmd)).toContain(`"merge"`);
    expect(req.sentAt).toBe(Date.UTC(2026, 10, 20, 12, 38));
    expect(req.deadline).toBe(Date.UTC(2026, 10, 20, 12, 39));
    expect(req.presence?.v).toBe(2);
  });

  it("un tipo desconocido se ignora", () => {
    expect(decodeFrame(utf8(`{"t":"later"}`))).toEqual({ t: "unknown", type: "later" });
  });
});

describe("chunks", () => {
  for (const [index, sample] of frames.chunks.entries()) {
    it(`#${index}: mismos trozos que la Mac y se rearman`, () => {
      const chunks = chunkFrame(utf8(sample.frame));
      expect(chunks.map(toHex)).toEqual(sample.chunks);
      const assembler = new FrameAssembler();
      const out = sample.chunks.map((hex) => assembler.add(fromHex(hex)));
      expect(text(out.at(-1)!)).toBe(sample.frame);
    });
  }

  it("un marco grande va en varios trozos, cada uno múltiplo de 256", () => {
    const data = new Uint8Array(MAX_CHUNK_DATA * 2 + 10).map((_, i) => i % 251);
    const chunks = chunkFrame(data);
    expect(chunks.length).toBe(3);
    expect(chunks.every((c) => c.length % 256 === 0 && c.length <= 65_280)).toBe(true);
    expect(chunks.map((c) => c[0])).toEqual([1, 1, 0]);
    const assembler = new FrameAssembler();
    expect(assembler.add(chunks[0]!)).toBeNull();
    expect(assembler.add(chunks[1]!)).toBeNull();
    expect(assembler.add(chunks[2]!)).toEqual(data);
  });

  it("un marco vacío es un trozo", () => {
    expect(chunkFrame(new Uint8Array(0)).map(toHex)).toEqual(["00".repeat(256)]);
  });

  it("rechaza trozos malformados y comprimidos", () => {
    const good = chunkFrame(utf8("{}"))[0]!;
    const bad = (mutate: (c: Uint8Array) => Uint8Array) => () => new FrameAssembler().add(mutate(good.slice()));
    expect(bad((c) => c.slice(0, 255))).toThrow(FramingError);
    expect(bad((c) => { c[0] = 2; return c; })).toThrow(FramingError);
    expect(bad((c) => { c[0] = 4; return c; })).toThrow(FramingError);
    expect(bad((c) => { c[2] = 254; return c; })).toThrow(FramingError);
    expect(bad((c) => { c[200] = 1; return c; })).toThrow(FramingError);
  });
});

describe("pairing messages", () => {
  for (const [index, sample] of frames.pairing.entries()) {
    it(`#${index} ${sample.type}: decode → encode da los mismos bytes`, () => {
      const message = decodePairingMessage(utf8(sample.text));
      expect(text(encodePairingMessage(message))).toBe(sample.text);
    });
  }

  it("join trae las claves como bytes", () => {
    const join = decodePairingMessage(utf8(frames.pairing[0]!.text));
    if (join.kind !== "join") throw new Error("not a join");
    expect(join.join.relayKey.length).toBe(32);
    expect(join.join.presence?.rpId).toBe("prbar.example.org");
  });
});
