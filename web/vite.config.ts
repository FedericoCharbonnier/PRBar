import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { build, type Plugin, type ResolvedConfig } from "vite";
import { defineConfig } from "vitest/config";
import { addIntegrity } from "./vite/integrity.ts";

// La app se sirve desde el relay con una CSP estricta (spec W.7): nada en línea (scripts, estilos ni data: de assets),
// assets con hash bajo `assets/` (inmutables) y el service worker en `/sw.js` sin hash (se revalida siempre).

function publicFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (current: string) => {
    for (const name of readdirSync(current)) {
      const path = join(current, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (!name.startsWith(".")) out.push(`/${relative(dir, path).split("\\").join("/")}`);
    }
  };
  try {
    walk(dir);
  } catch {
    // Sin `public/`.
  }
  return out;
}

/** El service worker se compila aparte (un solo archivo IIFE, sin imports compartidos con la página) con lo que hay que
 *  precargar: el `index.html`, los assets con hash de este build y los archivos de `public/`, cada uno con el SHA-256
 *  de su contenido (el service worker lo verifica al instalar; sw/precache.ts). Antes, el `index.html` construido
 *  recibe SRI en sus scripts y hojas de estilo (vite/integrity.ts). El nombre de la caché sale de esos hashes y de la
 *  versión de package.json (otra versión = otro `sw.js` = otra caché; subirla fuerza una reinstalación, ver
 *  relay/README.md). */
function serviceWorker(): Plugin {
  let config: ResolvedConfig;
  let files: string[] = [];
  return {
    name: "prbar-service-worker",
    apply: "build",
    configResolved(resolved) {
      config = resolved;
    },
    generateBundle(_options, bundle) {
      files = Object.keys(bundle).map((name) => `/${name}`);
    },
    async closeBundle() {
      const outDir = resolve(config.root, config.build.outDir);
      const sha256 = (path: string) => createHash("sha256").update(readFileSync(join(outDir, path))).digest("base64");
      // SRI en el `index.html` ya escrito (antes de hashearlo para el service worker).
      const indexPath = join(outDir, "index.html");
      writeFileSync(indexPath, addIntegrity(readFileSync(indexPath, "utf8"), sha256));

      const publicDir = config.publicDir;
      const extra = publicDir ? publicFiles(publicDir) : [];
      // `index.html` lo escribe Vite después de este `generateBundle`: se agrega a mano.
      const paths = [...new Set(["/index.html", ...files, ...extra])].filter((f) => f !== "/sw.js").sort();
      const precache: Record<string, string> = {};
      for (const path of paths) precache[path] = sha256(path);
      const version = JSON.parse(readFileSync(resolve(config.root, "package.json"), "utf8")).version as string;
      const hash = createHash("sha256").update(version).update("\0");
      for (const path of paths) hash.update(path).update("\0").update(precache[path]!).update("\0");
      const cache = `prbar-${hash.digest("hex").slice(0, 16)}`;
      await build({
        configFile: false,
        root: config.root,
        logLevel: "warn",
        mode: config.mode,
        define: {
          __PRBAR_PRECACHE__: JSON.stringify(precache),
          __PRBAR_CACHE__: JSON.stringify(cache),
          "import.meta.env.MODE": JSON.stringify(config.mode),
        },
        build: {
          outDir: resolve(config.root, config.build.outDir),
          emptyOutDir: false,
          copyPublicDir: false,
          sourcemap: false,
          minify: true,
          lib: { entry: resolve(config.root, "src/sw.ts"), formats: ["iife"], name: "PRBarServiceWorker", fileName: () => "sw.js" },
        },
      });
    },
  };
}

export default defineConfig({
  base: "/",
  plugins: [serviceWorker()],
  build: {
    outDir: "dist",
    assetsDir: "assets",
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    sourcemap: false,
    rollupOptions: {
      input: { index: "index.html" },
      output: {
        entryFileNames: "assets/[name]-[hash].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
  test: {
    include: ["test/**/*.test.ts", "test/**/*.test.tsx"],
    environment: "node",
  },
});
