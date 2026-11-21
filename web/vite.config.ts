import { defineConfig } from "vitest/config";

// La app se sirve desde el relay con una CSP estricta (spec W.7): nada en línea (scripts, estilos ni data: de assets),
// assets con hash bajo `assets/` (inmutables) y el service worker en `/sw.js` sin hash (se revalida siempre).
export default defineConfig({
  base: "/",
  build: {
    outDir: "dist",
    assetsDir: "assets",
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    sourcemap: false,
    rollupOptions: {
      input: {
        index: "index.html",
        sw: "src/sw.ts",
      },
      output: {
        entryFileNames: (chunk) => (chunk.name === "sw" ? "sw.js" : "assets/[name]-[hash].js"),
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
