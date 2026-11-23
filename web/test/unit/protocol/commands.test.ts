import { describe, expect, it } from "vitest";
import { utf8 } from "../../../src/crypto/bytes";
import { decodeFrame, encodeFrame, decodeResponse } from "../../../src/protocol/appFrames";
import {
  commandName, commandText, decidePolicy, decodeActivity, decodeCommand, decodeHome, decodePRDetail, decodeResult,
  encodeCommand, GATED_NAMES, parseTopic, PHONE_COMMANDS, type AppCommand,
} from "../../../src/protocol/commands";
import { DecodeError, swiftJSON } from "../../../src/protocol/json";
import { COMMAND_PROTOCOL, MINIMUM_REMOTE_VERSION } from "../../../src/protocol/version";
import { fixture, type AppFixtureFile } from "../fixtures";

const app = fixture<AppFixtureFile>("app.json");
const text = (data: Uint8Array) => new TextDecoder().decode(data);

describe("commands (app.json)", () => {
  for (const [index, sample] of app.commands.entries()) {
    describe(`#${index} ${sample.name} (${sample.policy})`, () => {
      it("decode → encode da los mismos bytes", () => {
        const command = decodeCommand(sample.text);
        expect(command).toEqual(sample.json);
        expect(text(encodeCommand(command))).toBe(sample.text);
        expect(commandText(sample.json as AppCommand)).toBe(sample.text);
        expect(commandName(command)).toBe(sample.name);
      });

      it("misma política que RemotePolicy", () => {
        expect(decidePolicy(decodeCommand(sample.text))).toBe(sample.policy);
      });

      it("la respuesta y los eventos decodifican y se reescriben iguales", () => {
        const frame = decodeFrame(utf8(sample.responseText.replace(/^\{/, `{"t":"res",`)));
        if (frame.t !== "res") throw new Error("not a res");
        const { t: _t, ...response } = frame;
        expect(swiftJSON(response)).toBe(sample.responseText);
        expect(response.ok).toBe(true);
        decodeResult(commandName(decodeCommand(sample.text)), response.result);
        for (const event of sample.events ?? []) {
          const decoded = decodeResponse(event as Record<string, unknown>);
          expect(decoded.event).toBeDefined();
          expect(swiftJSON(decoded)).toBe(swiftJSON(event));
        }
      });
    });
  }

  it("cubre todos los comandos que el teléfono puede mandar", () => {
    expect(new Set(app.commands.map((c) => c.name))).toEqual(new Set(PHONE_COMMANDS));
  });

  it("los nombres gated son los de la Mac, en el mismo orden", () => {
    expect([...GATED_NAMES]).toEqual(app.gated);
  });

  it("versión de protocolo", () => {
    expect(COMMAND_PROTOCOL).toBe(app.protocolVersion);
    expect(MINIMUM_REMOTE_VERSION).toBe(app.minimumRemoteVersion);
  });

  it("rechaza comandos denegados, con varios casos o con tipos incorrectos", () => {
    expect(() => decodeCommand(`{"quit":{}}`)).toThrow(DecodeError);
    expect(() => decodeCommand(`{"slackTokenSet":{"token":"x"}}`)).toThrow(DecodeError);
    expect(() => decodeCommand(`{"status":{},"refresh":{}}`)).toThrow(DecodeError);
    expect(() => decodeCommand(`{"merge":{"pr":"a/b#1","confirmed":"yes","expectedHeadOid":"x"}}`)).toThrow(DecodeError);
    expect(() => decodeCommand(`{"merge":{"pr":"a/b#1","confirmed":true}}`)).toThrow(DecodeError);
    expect(() => decodeCommand(`{"merge":{"pr":"a/b#1","method":"fast","confirmed":true,"expectedHeadOid":"x"}}`))
      .toThrow(DecodeError);
    expect(() => decodeCommand(`{"notifySet":{"kind":"spam","enabled":true}}`)).toThrow(DecodeError);
  });

  it("todo lo que publica en GitHub es gated; editar el borrador no", () => {
    for (const event of ["COMMENT", "REQUEST_CHANGES", "APPROVE"] as const) {
      expect(decidePolicy({ reviewPublish: { pr: "a/b#1", event, withComments: true, allInBody: false, confirmed: true } }))
        .toBe("gated");
    }
    expect(decidePolicy({ respondReplyOnly: { pr: "a/b#1", confirmed: true, wait: false } })).toBe("gated");
    expect(decidePolicy({ respondSelect: { pr: "a/b#1", items: ["1"], change: { replyText: "x" } } })).toBe("allowed");
  });

  it("apagar Face ID es gated; prenderlo no", () => {
    expect(decidePolicy({ remoteSetPresenceRequirement: { device: "", enabled: false } })).toBe("gated");
    expect(decidePolicy({ remoteSetPresenceRequirement: { device: "", enabled: true } })).toBe("allowed");
  });
});

describe("errors (app.json)", () => {
  for (const [index, sample] of app.errors.entries()) {
    it(`#${index}`, () => {
      const response = decodeResponse(sample as Record<string, unknown>);
      expect(response.ok).toBe(false);
      expect(response.error?.message).toBeTruthy();
      expect(swiftJSON(response)).toBe(swiftJSON(sample));
    });
  }
});

describe("topics (app.json)", () => {
  for (const sample of app.topics) {
    it(`${sample.topic}: decode → encode da los mismos bytes`, () => {
      const topic = parseTopic(sample.topic);
      expect(topic).not.toBeNull();
      const data = JSON.parse(sample.text) as unknown;
      if (topic!.kind === "home") expect(decodeHome(data).prs.length).toBeGreaterThan(0);
      else if (topic!.kind === "activity") expect(decodeActivity(data).history.length).toBeGreaterThan(0);
      else expect(decodePRDetail(data).pr?.id).toBe(topic!.id);
      expect(swiftJSON(data)).toBe(sample.text);
      // Dentro de un marco `state`.
      const frame = { t: "state" as const, topic: sample.topic, rev: 1, data: data as never };
      expect(decodeFrame(encodeFrame(frame))).toEqual(frame);
    });
  }

  it("parseTopic valida los ids como la Mac", () => {
    expect(parseTopic("pr:acme/web-app#488")).toEqual({ kind: "pr", id: "acme/web-app#488" });
    for (const bad of ["pr:acme#1", "pr:acme/api#0", "pr:acme/api#01", "pr:a/b/c#1", "pr:acme/a pi#1", "x", "pr:"]) {
      expect(parseTopic(bad)).toBeNull();
    }
  });

  it("decodeHome rechaza un home sin status", () => {
    expect(() => decodeHome({ prs: [], ci: [] })).toThrow(DecodeError);
  });
});
