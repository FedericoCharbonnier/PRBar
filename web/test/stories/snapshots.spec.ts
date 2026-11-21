import { expect, test, type Page } from "@playwright/test";

// Captura cada historia del arnés en claro y oscuro. La lista sale del índice del arnés (los enlaces), así no se
// duplica el registro de historias acá.

const OUT = "test/snapshots";

async function storyIds(page: Page): Promise<{ id: string; file: string }[]> {
  await page.goto("/stories.html#/");
  await page.waitForSelector(".story-index li");
  return page.$$eval(".story-index li", (items) =>
    items.map((li) => ({
      id: li.querySelector("a")?.getAttribute("href")?.replace(/^#\//, "") ?? "",
      file: li.querySelector("small")?.textContent?.trim() ?? "",
    })),
  );
}

for (const theme of ["light", "dark"] as const) {
  test(`stories (${theme})`, async ({ page }) => {
    test.setTimeout(120_000);
    await page.emulateMedia({ colorScheme: theme, reducedMotion: "reduce" });
    const ids = await storyIds(page);
    expect(ids.length).toBeGreaterThan(20);
    for (const { id, file } of ids) {
      await page.goto(`/stories.html#/${id}`);
      await page.evaluate(() => document.fonts.ready);
      // Las hojas se dibujan en #overlay-root (fuera de #app).
      await page.waitForSelector("#app > *, #overlay-root > *");
      // Congela animaciones (spinners) para que las capturas sean estables.
      await page.addStyleTag({ content: "*,*::before,*::after{animation-play-state:paused!important;animation-delay:-0.3s!important;transition:none!important;caret-color:transparent!important}" });
      // Y las de la Web Animations API (la entrada de hojas y menús) quedan en su cuadro final.
      await page.evaluate(() => {
        for (const a of document.getAnimations()) {
          if (typeof CSSAnimation !== "undefined" && a instanceof CSSAnimation) continue;
          try {
            a.finish();
          } catch {
            // Infinita: no aplica.
          }
        }
      });
      await page.screenshot({ path: `${OUT}/${file}-${theme}.png`, fullPage: id === "review-full" });
    }
  });
}
