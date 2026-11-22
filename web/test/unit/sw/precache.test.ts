import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { fetchVerified, sha256Base64, verifyBody } from "../../../src/sw/precache";
import { addIntegrity } from "../../../vite/integrity";

const enc = new TextEncoder();
const nodeHash = (text: string) => createHash("sha256").update(text).digest("base64");

describe("sw precache verification", () => {
  it("hashes like the build (SHA-256, base64 estándar)", async () => {
    expect(await sha256Base64(enc.encode(""))).toBe("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=");
    expect(await sha256Base64(enc.encode("console.log(1)"))).toBe(nodeHash("console.log(1)"));
  });

  it("accepts a matching body and rejects any other", async () => {
    await expect(verifyBody("/a.js", enc.encode("ok"), nodeHash("ok"))).resolves.toBeUndefined();
    await expect(verifyBody("/a.js", enc.encode("evil"), nodeHash("ok"))).rejects.toThrow("/a.js");
    await expect(verifyBody("/a.js", enc.encode("ok"), undefined)).rejects.toThrow("no hash");
    await expect(verifyBody("/a.js", enc.encode("ok"), "")).rejects.toThrow("no hash");
  });

  it("fetches every file bypassing the HTTP cache and returns them only if all match", async () => {
    const bodies: Record<string, string> = { "/index.html": "<html>", "/assets/a.js": "a" };
    const calls: { path: string; cache: RequestCache | undefined }[] = [];
    const fetchFn = async (path: string, init: RequestInit) => {
      calls.push({ path, cache: init.cache });
      return new Response(bodies[path] ?? "", { status: bodies[path] === undefined ? 404 : 200 });
    };
    const manifest = { "/index.html": nodeHash("<html>"), "/assets/a.js": nodeHash("a") };
    const verified = await fetchVerified(manifest, fetchFn);
    expect(calls.map((c) => c.cache)).toEqual(["reload", "reload"]);
    expect(verified.map(([p]) => p).sort()).toEqual(["/assets/a.js", "/index.html"]);
    // La respuesta guardada conserva el cuerpo (se hasheó un clon).
    const index = verified.find(([p]) => p === "/index.html")![1];
    expect(await index.text()).toBe("<html>");

    // Un archivo envenenado (o que falta) hace fallar toda la instalación.
    bodies["/assets/a.js"] = "evil";
    await expect(fetchVerified(manifest, fetchFn)).rejects.toThrow("/assets/a.js");
    delete bodies["/assets/a.js"];
    await expect(fetchVerified(manifest, fetchFn)).rejects.toThrow("404");
  });
});

describe("build SRI", () => {
  const hash = (path: string) => {
    if (path === "/assets/x.js") return "JS";
    if (path === "/assets/x.css") return "CSS";
    if (path === "/assets/y.js") return "Y";
    throw new Error(`missing ${path}`);
  };

  it("adds integrity and crossorigin to local scripts and stylesheets only", () => {
    const html = [
      `<script type="module" crossorigin src="/assets/x.js"></script>`,
      `<link rel="stylesheet" crossorigin href="/assets/x.css">`,
      `<link rel="modulepreload" href="/assets/y.js" />`,
      `<link rel="manifest" href="/manifest.webmanifest" />`,
      `<link rel="icon" href="/icons/icon-192.png" />`,
      `<script>inline()</script>`,
      `<script src="https://cdn.example/x.js"></script>`,
      `<script src="//cdn.example/x.js"></script>`,
      `<script src="/assets/x.js" integrity="sha256-keep"></script>`,
    ].join("\n");
    expect(addIntegrity(html, hash).split("\n")).toEqual([
      `<script type="module" crossorigin src="/assets/x.js" integrity="sha256-JS"></script>`,
      `<link rel="stylesheet" crossorigin href="/assets/x.css" integrity="sha256-CSS">`,
      `<link rel="modulepreload" href="/assets/y.js" integrity="sha256-Y" crossorigin />`,
      `<link rel="manifest" href="/manifest.webmanifest" />`,
      `<link rel="icon" href="/icons/icon-192.png" />`,
      `<script>inline()</script>`,
      `<script src="https://cdn.example/x.js"></script>`,
      `<script src="//cdn.example/x.js"></script>`,
      `<script src="/assets/x.js" integrity="sha256-keep"></script>`,
    ]);
  });

  it("fails the build when a referenced file is missing", () => {
    expect(() => addIntegrity(`<script src="/assets/gone.js"></script>`, hash)).toThrow("missing");
  });
});
