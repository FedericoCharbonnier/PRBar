import { defineConfig } from "vite";

// Arnés de historias (solo pruebas y capturas). Config aparte para que `stories.html` nunca entre en `dist/`.
export default defineConfig({
  base: "/",
  server: { port: 41739, strictPort: true },
  preview: { port: 41739, strictPort: true },
  build: {
    outDir: "test/.stories-dist",
    emptyOutDir: true,
    rollupOptions: { input: { stories: "stories.html" } },
  },
});
