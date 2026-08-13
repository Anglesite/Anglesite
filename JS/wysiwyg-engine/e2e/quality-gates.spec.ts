import { test, expect } from "@playwright/test";

test("a pushed finding renders a chip, and applying its fix submits the op and clears the chip", async ({ page }) => {
  await page.goto("/fixture.html");

  await page.evaluate(() => {
    window.__pushQualityFindings([
      {
        id: "b1::headingOrder",
        blockId: "b1",
        category: "headingOrder",
        severity: "warning",
        message: "This heading jumps from h2 to h4 — screen reader visitors navigating by heading will think content is missing.",
        fix: { kind: "setProp", blockId: "b1", propName: "title", value: "Fixed", previousValue: "Welcome" },
      },
    ]);
  });

  const chip = page.locator('[data-quality-chip-id="b1::headingOrder"]');
  await expect(chip).toContainText("screen reader visitors navigating by heading");

  await chip.getByRole("button", { name: "Apply" }).click();

  await expect(chip).toHaveCount(0);
  const title = await page.evaluate(() => window.__engine.modelSync.current.blocks.b1?.props.title);
  expect(title).toBe("Fixed");
});

test("a finding with no fix renders a chip with no Apply button", async ({ page }) => {
  await page.goto("/fixture.html");

  await page.evaluate(() => {
    window.__pushQualityFindings([
      { id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt text" },
    ]);
  });

  const chip = page.locator('[data-quality-chip-id="b1::altText"]');
  await expect(chip).toContainText("missing alt text");
  await expect(chip.getByRole("button")).toHaveCount(0);
});
