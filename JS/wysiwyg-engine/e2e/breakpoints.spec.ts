import { test, expect } from "@playwright/test";

test("registers all three frames and renders the model into each", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  for (const name of ["phone", "tablet", "desktop"]) {
    const frame = page.frameLocator(`#${name}`);
    await expect(frame.locator('[data-anglesite-block-id="b1"]')).toHaveText("Hero");
  }
});

test("selecting a block in one frame draws handles in every registered frame", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  await page.frameLocator("#phone").locator('[data-anglesite-block-id="b2"]').click();
  await page.waitForFunction(() => document.title === "event:selection-changed");

  const rects = await page.evaluate(() => window.__handleRects());
  expect(rects.map((r) => r.name).sort()).toEqual(["desktop", "phone", "tablet"]);
  for (const { rect } of rects) {
    expect(rect.width).toBeGreaterThan(0);
    expect(rect.height).toBeGreaterThan(0);
  }
});

test("an op applied via the shared engine re-renders every frame", async ({ page }) => {
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  await page.evaluate(() =>
    window.__engine.submit({
      kind: "moveBlock",
      blockId: "b2",
      fromParentId: "__root__",
      fromSlot: "default",
      fromIndex: 1,
      toParentId: "__root__",
      toSlot: "default",
      toIndex: 0,
    }),
  );
  await page.waitForFunction(() => document.title === "event:applied");

  for (const name of ["phone", "tablet", "desktop"]) {
    const frame = page.frameLocator(`#${name}`);
    await expect(frame.locator("#canvas > div").first()).toHaveText("Testimonial");
  }
});
