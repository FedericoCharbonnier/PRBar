import { readFileSync } from "node:fs";

// Carga los vectores cruzados que genera la Mac (`web/test/fixtures/`).

const dir = new URL("../fixtures/", import.meta.url);

export function fixture<T>(name: string): T {
  return JSON.parse(readFileSync(new URL(name, dir), "utf8")) as T;
}

export interface FramesFixture {
  relay: { type: string; text: string }[];
  app: { type: string; text: string }[];
  pairing: { type: string; text: string }[];
  chunks: { frame: string; chunks: string[] }[];
}

export interface AppFixtureCommand {
  name: string;
  policy: "allowed" | "gated";
  text: string;
  json: unknown;
  response: unknown;
  responseText: string;
  events?: unknown[];
}

export interface AppFixtureFile {
  commands: AppFixtureCommand[];
  topics: { topic: string; text: string; json: unknown }[];
  errors: unknown[];
  push: unknown[];
  gated: string[];
  minimumRemoteVersion: number;
  protocolVersion: number;
}

export interface NoiseFixture {
  account: string;
  device: string;
  handshake_hash: string;
  init_ephemeral: string;
  init_prologue: string;
  init_remote_static: string;
  init_static: string;
  init_psks?: string[];
  resp_ephemeral: string;
  resp_static: string;
  resp_psks?: string[];
  messages: { ciphertext: string; payload: string; frame?: string }[];
  // Solo en noise-ikpsk2.json.
  pairing?: string;
  ps?: string;
  pairAuthKey?: string;
  macSeal?: string;
  devicePushPublic?: string;
  deviceRelayPublic?: string;
  sas?: string;
}
