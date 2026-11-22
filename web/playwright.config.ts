import { defineConfig } from "@playwright/test";

// E2E (C7): `Scripts/web-e2e.sh` compila el relay con la web embebida y la Mac simulada y corre esto. Cada archivo
// levanta su propio relay, push falso y Mac simulada (test/e2e/fixtures.ts). Las capturas van aparte
// (`npm run snapshots`, playwright.stories.config.ts).
export default defineConfig({
  testDir: "test/e2e",
  outputDir: "test/e2e/.results",
  timeout: 90_000,
  expect: { timeout: 15_000 },
  workers: 2,
  reporter: "list",
  use: { trace: "retain-on-failure" },
  projects: [
    { name: "chromium", testMatch: /chromium\.spec\.ts/, use: { browserName: "chromium", channel: "chromium" } },
    { name: "webkit", testMatch: /webkit\.spec\.ts/, use: { browserName: "webkit" } },
  ],
});
