import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");

// Los tokens simples de la tabla de DESIGN.md (`a / b` cuenta como dos). Los que no son colores fijos por tema
// (glass, connected dot, badge, app tile) se mapean a mano abajo.
function designTokens(): string[] {
  const design = read("design/DESIGN.md");
  const table = design.split("## Tokens")[1]?.split("\n## ")[0] ?? "";
  const names: string[] = [];
  for (const line of table.split("\n")) {
    const cell = line.split("|")[1]?.trim();
    if (!cell || cell === "Token" || cell.startsWith("---")) continue;
    for (const name of cell.split("/").map((s) => s.trim())) names.push(name);
  }
  return names;
}

const special: Record<string, string> = {
  "connected dot": "connected",
  "app tile": "apptile",
};

function block(css: string, dark: boolean): string {
  const [light, rest] = css.split("@media (prefers-color-scheme: dark)");
  return (dark ? rest : light) ?? "";
}

describe("tokens.css", () => {
  const css = read("src/ui/tokens.css");

  it("define cada token de DESIGN.md", () => {
    const tokens = designTokens();
    expect(tokens.length).toBeGreaterThan(30);
    for (const token of tokens) {
      const name = special[token] ?? token;
      expect(block(css, false), `--${name}`).toContain(`--${name}:`);
    }
  });

  it("los colores claros y oscuros coinciden con la tabla", () => {
    const light = block(css, false);
    const dark = block(css, true);
    expect(light).toContain("--bg: #f2f2f7;");
    expect(dark).toContain("--bg: #000000;");
    expect(light).toContain("--accent: #2d4eff;");
    expect(dark).toContain("--accent: #3b5bff;");
    expect(dark).toContain("--accentfg: #8fa3ff;");
    expect(light).toContain("--sep: rgba(60, 60, 67, 0.18);");
    expect(dark).toContain("--violet: #d2b3ff;");
  });

  it("cada token con variante oscura en DESIGN.md se redefine en modo oscuro", () => {
    const dark = block(css, true);
    for (const name of ["bg", "bg2", "bg3", "sheet", "fg", "fg2", "fg3", "sep", "fill", "fill2", "accent", "accentfg",
      "accentbg", "green", "greenbg", "orange", "orangebg", "red", "redbg", "violet", "violetbg", "blue", "bluebg",
      "codebg", "addbg", "delbg", "hud"]) {
      expect(dark, `--${name}`).toContain(`--${name}:`);
    }
  });
});

describe("index.html", () => {
  const html = read("index.html");

  it("no tiene scripts ni estilos en línea (CSP estricta)", () => {
    expect(html).not.toMatch(/<style/i);
    expect(html).not.toMatch(/\sstyle=/i);
    for (const tag of html.match(/<script[^>]*>/gi) ?? []) expect(tag).toMatch(/\ssrc=/);
    expect(html).not.toMatch(/\son[a-z]+=/i);
  });

  it("declara viewport-fit=cover, la app de inicio y el manifest", () => {
    expect(html).toContain("viewport-fit=cover");
    expect(html).toContain('name="apple-mobile-web-app-capable" content="yes"');
    expect(html).toContain('rel="manifest" href="/manifest.webmanifest"');
    expect(html).toContain('href="/icons/apple-touch-icon-180.png"');
  });
});

describe("manifest", () => {
  const manifest = JSON.parse(read("public/manifest.webmanifest")) as {
    name: string; display: string; theme_color: string; background_color: string; icons: { src: string; sizes: string }[];
  };

  it("es standalone con los íconos 180/192/512", () => {
    expect(manifest.name).toBe("PRBar");
    expect(manifest.display).toBe("standalone");
    expect(manifest.theme_color.toLowerCase()).toBe("#f2f2f7");
    expect(manifest.icons.map((i) => i.sizes)).toEqual(["180x180", "192x192", "512x512", "512x512"]);
    for (const icon of manifest.icons) expect(() => readFileSync(new URL(`../../public${icon.src}`, import.meta.url))).not.toThrow();
  });
});
