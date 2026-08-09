import { test, expect } from "@playwright/test";

test("typing in an entered text block commits an editText op with honest runs after the debounce", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.evaluate((el) => {
    el.textContent = "Edit me now";
  });
  await block.dispatchEvent("input");

  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([{ kind: "text", text: "Edit me now" }]);
});

test("toggling bold on a selection wraps it in <strong>, never a styled span", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.evaluate((el) => {
    const textNode = el.firstChild;
    if (!textNode) throw new Error("expected a text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 4); // "Edit" (of "Edit ")
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });

  await page.evaluate(() => window.__toggleFormat("strong"));
  await page.evaluate(() => window.__richText.exit());
  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([
    { kind: "strong", text: "Edit" },
    { kind: "text", text: " " },
    { kind: "strong", text: "me" },
  ]);
});

test("exiting without any change does not submit a no-op editText", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  await page.evaluate(() => window.__richText.exit());

  // No typing happened, so nothing should have committed — the title (flipped only by engine
  // events) stays at its initial, pre-any-event value.
  await page.waitForTimeout(100);
  expect(await page.title()).toBe("WYSIWYG engine fixture");
});
