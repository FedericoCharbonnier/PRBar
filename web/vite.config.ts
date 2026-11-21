import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { build, type Plugin, type ResolvedConfig } from "vite";
import { defineConfig } from "vitest/config";

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

/** El service worker se compila aparte (un solo archivo IIFE, sin imports compartidos con la página) con la lista de
 *  lo que hay que precargar: el `index.html`, los assets con hash de este build y los archivos de `public/`. El nombre
 *  de la caché sale de un hash de esa lista y del contenido de `public/` (otra versión = otra caché). */
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
      const publicDir = config.publicDir;
      const extra = publicDir ? publicFiles(publicDir) : [];
      // `index.html` lo escribe Vite después de este `generateBundle`: se agrega a mano.
      const precache = [...new Set(["/index.html", ...files, ...extra])].filter((f) => f !== "/sw.js").sort();
      const hash = createHash("sha256");
      for (const file of precache) hash.update(file).update("\0");
      for (const file of extra) hash.update(readFileSync(join(publicDir, file)));
      // El `index.html` cambia con cada build que cambia los assets, pero también por sí solo.
      hash.update(readFileSync(resolve(config.root, config.build.outDir, "index.html")));
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
