import { defineConfig } from "@playwright/test";

// `npm run snapshots`: capturas de cada historia (393×852 @3x, claro y oscuro) en test/snapshots/.
// Levanta el arnés de historias con Vite (config aparte; nunca va al build de producción).
export default defineConfig({
  testDir: "test/stories",
  outputDir: "test/stories/.results",
  fullyParallel: true,
  reporter: "list",
  use: {
    browserName: "chromium",
    baseURL: "http://localhost:41739",
    viewport: { width: 393, height: 852 },
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
  },
  webServer: {
    command: "npx vite --config vite.stories.config.ts",
    url: "http://localhost:41739/stories.html",
    reuseExistingServer: !process.env["CI"],
    timeout: 60_000,
  },
});
