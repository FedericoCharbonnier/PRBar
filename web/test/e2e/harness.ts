import { spawn, type ChildProcess } from "node:child_process";
import { createDecipheriv, createECDH, createHmac, generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

// Lo que levanta cada archivo e2e: el relay de Go en modo test (con la web embebida), un servicio de push falso que
// captura lo que manda el relay y la Mac simulada (`prbar-remote-fixture serve`). `Scripts/web-e2e.sh` compila los
// binarios y pasa sus rutas en PRBAR_RELAY_BIN y PRBAR_FIXTURE_BIN.

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set: run Scripts/web-e2e.sh`);
  return value;
}

export function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createNetServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(port));
    });
  });
}

const b64url = (data: Buffer) => data.toString("base64url");

// --- Servicio de push falso ---

export interface CapturedPush {
  path: string;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}

export class PushCapture {
  readonly pushes: CapturedPush[] = [];
  #server: Server | null = null;
  #waiters: (() => void)[] = [];
  port = 0;

  async start(): Promise<void> {
    this.port = await freePort();
    this.#server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => {
        this.pushes.push({ path: req.url ?? "", headers: req.headers, body: Buffer.concat(chunks) });
        res.writeHead(201).end();
        for (const w of this.#waiters.splice(0)) w();
      });
    });
    await new Promise<void>((resolve) => this.#server!.listen(this.port, "127.0.0.1", resolve));
  }

  get prefix(): string {
    return `http://127.0.0.1:${this.port}/push/`;
  }

  async next(count: number, timeoutMs = 15_000): Promise<CapturedPush> {
    const deadline = Date.now() + timeoutMs;
    while (this.pushes.length < count) {
      if (Date.now() > deadline) throw new Error("no push arrived at the fake push service");
      await new Promise<void>((resolve) => {
        this.#waiters.push(resolve);
        setTimeout(resolve, 250);
      });
    }
    return this.pushes[count - 1]!;
  }

  stop(): void {
    this.#server?.close();
  }
}

/** Una suscripción de Web Push con claves que controla la prueba (la del navegador no sirve sin red). */
export class TestSubscription {
  readonly #ecdh = createECDH("prime256v1");
  readonly auth = randomBytes(16);
  readonly p256dh: Buffer;

  constructor(readonly endpoint: string) {
    this.p256dh = this.#ecdh.generateKeys();
  }

  get json(): { endpoint: string; p256dh: string; auth: string } {
    return { endpoint: this.endpoint, p256dh: b64url(this.p256dh), auth: b64url(this.auth) };
  }

  /** RFC 8291 (`aes128gcm`, un registro): el texto plano del push. */
  decrypt(body: Buffer): Buffer {
    const salt = body.subarray(0, 16);
    const idlen = body[20]!;
    const asPublic = body.subarray(21, 21 + idlen);
    const ciphertext = body.subarray(21 + idlen);
    const shared = this.#ecdh.computeSecret(asPublic);
    const hmac = (key: Buffer, data: Buffer) => createHmac("sha256", key).update(data).digest();
    const expand = (prk: Buffer, info: Buffer, length: number) => hmac(prk, Buffer.concat([info, Buffer.of(1)])).subarray(0, length);
    const keyInfo = Buffer.concat([Buffer.from("WebPush: info\0"), this.p256dh, asPublic]);
    const ikm = expand(hmac(this.auth, shared), keyInfo, 32);
    const prk = hmac(salt, ikm);
    const cek = expand(prk, Buffer.from("Content-Encoding: aes128gcm\0"), 16);
    const nonce = expand(prk, Buffer.from("Content-Encoding: nonce\0"), 12);
    const decipher = createDecipheriv("aes-128-gcm", cek, nonce);
    decipher.setAuthTag(ciphertext.subarray(ciphertext.length - 16));
    const padded = Buffer.concat([decipher.update(ciphertext.subarray(0, ciphertext.length - 16)), decipher.final()]);
    let end = padded.length - 1;
    while (end >= 0 && padded[end] === 0) end--;
    if (padded[end] !== 2) throw new Error("push: bad padding delimiter");
    return padded.subarray(0, end);
  }
}

// --- Relay ---

export class Relay {
  #process: ChildProcess | null = null;
  readonly #data = mkdtempSync(join(process.env["PRBAR_E2E_TMP"] ?? tmpdir(), "relay-"));
  readonly log: string[] = [];
  readonly enrollToken = randomBytes(32).toString("hex");
  port = 0;

  get origin(): string {
    return `http://localhost:${this.port}`;
  }

  async start(pushPrefix: string): Promise<void> {
    this.port = await freePort();
    // Un par VAPID de prueba (el escalar `d` en base64url).
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const vapid = privateKey.export({ format: "jwk" }).d!;
    this.#process = spawn(required("PRBAR_RELAY_BIN"), [], {
      env: {
        PATH: process.env["PATH"] ?? "",
        RELAY_LISTEN: `127.0.0.1:${this.port}`,
        RELAY_DATA: this.#data,
        RELAY_PUBLIC_HOST: "localhost",
        RELAY_ENROLL_TOKEN: this.enrollToken,
        RELAY_TRUSTED_PROXIES: "none",
        RELAY_TEST_MODE: "1",
        WEBPUSH_TEST_ENDPOINT: pushPrefix,
        VAPID_PRIVATE_KEY: vapid,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    for (const stream of [this.#process.stdout!, this.#process.stderr!]) {
      createInterface({ input: stream }).on("line", (line) => this.log.push(line));
    }
    for (let i = 0; i < 200; i++) {
      try {
        const res = await fetch(`http://127.0.0.1:${this.port}/healthz`);
        if ((await res.text()) === "ok") return;
      } catch {
        // Todavía no escucha.
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error(`the relay didn't start:\n${this.log.join("\n")}`);
  }

  stop(): void {
    this.#process?.kill("SIGTERM");
    rmSync(this.#data, { recursive: true, force: true });
  }
}

// --- La Mac simulada ---

export type MacEvent = { event: string } & Record<string, unknown>;

export interface MacState {
  merged: string[];
  approved: string[];
  pushed: string[];
  calls: string[];
}

export class FakeMac {
  readonly events: MacEvent[] = [];
  readonly stderr: string[] = [];
  #process: ChildProcess | null = null;
  readonly #state = mkdtempSync(join(process.env["PRBAR_E2E_TMP"] ?? tmpdir(), "mac-"));
  #waiters: (() => void)[] = [];

  async start(relay: Relay): Promise<void> {
    this.#process = spawn(required("PRBAR_FIXTURE_BIN"), [
      "serve", "--relay", `ws://localhost:${relay.port}`, "--enroll-token", relay.enrollToken, "--state", this.#state,
      "--web-origin", relay.origin,
    ], { stdio: ["pipe", "pipe", "pipe"] });
    createInterface({ input: this.#process.stdout! }).on("line", (line) => {
      try {
        this.events.push(JSON.parse(line) as MacEvent);
      } catch {
        this.stderr.push(line);
      }
      for (const w of this.#waiters.splice(0)) w();
    });
    createInterface({ input: this.#process.stderr! }).on("line", (line) => this.stderr.push(line));
    await this.waitFor("ready", undefined, 30_000);
  }

  send(command: string): void {
    this.#process!.stdin!.write(`${command}\n`);
  }

  /** El primer evento `name` desde `from` (índice en `events`) que cumple `match`. */
  async waitFor(name: string, match?: (event: MacEvent) => boolean, timeoutMs = 20_000, from = 0): Promise<MacEvent> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.events.slice(from).find((e) => e.event === name && (!match || match(e)));
      if (found) return found;
      const failed = this.events.slice(from).find((e) => e.event === "error");
      if (failed && name !== "error") throw new Error(`fake Mac: ${String(failed["message"])}`);
      if (Date.now() > deadline) {
        throw new Error(`fake Mac: no ${name} event. Events: ${JSON.stringify(this.events)}\n${this.stderr.join("\n")}`);
      }
      await new Promise<void>((resolve) => {
        this.#waiters.push(resolve);
        setTimeout(resolve, 250);
      });
    }
  }

  /** Manda `command` y espera el evento `name` que llega después. */
  async request(command: string, name: string, match?: (event: MacEvent) => boolean, timeoutMs?: number): Promise<MacEvent> {
    const from = this.events.length;
    this.send(command);
    return this.waitFor(name, match, timeoutMs, from);
  }

  /** Lo que hicieron las acciones simuladas (merge, approve, push…). */
  async state(): Promise<MacState> {
    return (await this.request("state", "state")) as unknown as MacState;
  }

  /** Los dispositivos emparejados (`id`, `name`, `online`, `notifications`, `requirePresence`). */
  async devices(): Promise<Record<string, unknown>[]> {
    return (await this.request("devices", "devices"))["devices"] as Record<string, unknown>[];
  }

  stop(): void {
    try {
      this.#process?.stdin?.end("quit\n");
    } catch {
      // Ya terminó.
    }
    const child = this.#process;
    setTimeout(() => child?.kill("SIGKILL"), 2000).unref();
    rmSync(this.#state, { recursive: true, force: true });
  }
}
