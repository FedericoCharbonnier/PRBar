import { defineConfig } from "@playwright/test";

// E2E y capturas (C7). `Scripts/web-e2e.sh` levanta el relay, la Mac simulada y la web antes de correr esto.
export default defineConfig({
  testDir: "test/e2e",
  outputDir: "test/e2e/.results",
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "webkit", use: { browserName: "webkit" } },
    { name: "snapshots", testMatch: /snapshots\.spec\.ts/, use: { browserName: "webkit" } },
  ],
});
