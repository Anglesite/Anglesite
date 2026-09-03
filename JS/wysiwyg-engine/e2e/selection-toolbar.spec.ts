import { test, expect } from "@playwright/test";

/** Selects "Edit" (the first 4 characters of t1's leading text node — see fixture-page.ts's
 *  `initialModel`) the same way rich-text.spec.ts's bold-toggle test does, then waits a tick for
 *  the browser's own `selectionchange` event (fired asynchronously, unlike jsdom) to reach
 *  `SelectionToolbar`. */
async function selectEditWord(page: import("@playwright/test").Page): Promise<void> {
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
}

const toolbar = (page: import("@playwright/test").Page) => page.locator("[data-selection-toolbar]");

test("selecting text inside an editable block shows Rewrite/Tighten/tone buttons", async ({ page }) => {
  await page.goto("/fixture.html");
  await selectEditWord(page);

  const bar = toolbar(page);
  await expect(bar).toHaveCount(1);
  await expect(bar.getByRole("button", { name: "Rewrite" })).toBeVisible();
  await expect(bar.getByRole("button", { name: "Tighten" })).toBeVisible();
  await expect(bar.getByRole("button", { name: "Friendlier" })).toBeVisible();
  await expect(bar.getByRole("button", { name: "More Formal" })).toBeVisible();
  await expect(bar.getByRole("button", { name: "More Confident" })).toBeVisible();
});

test("clearing the selection hides the toolbar", async ({ page }) => {
  await page.goto("/fixture.html");
  await selectEditWord(page);
  await expect(toolbar(page)).toHaveCount(1);

  await page.evaluate(() => window.getSelection()?.removeAllRanges());
  await expect(toolbar(page)).toHaveCount(0);
});

test("clicking Rewrite shows a loading state, then a preview with Accept/Discard", async ({ page }) => {
  await page.goto("/fixture.html");
  await selectEditWord(page);

  await toolbar(page).getByRole("button", { name: "Rewrite" }).click();
  await expect(toolbar(page)).toContainText("Rewriting");

  await page.evaluate(() => window.__resolveWritingHelp({ status: "rewritten", text: "Modify" }));

  await expect(toolbar(page)).toContainText("Modify");
  await expect(toolbar(page).getByRole("button", { name: "Accept" })).toBeVisible();
  await expect(toolbar(page).getByRole("button", { name: "Discard" })).toBeVisible();
});

test("clicking Accept replaces the selected text in the DOM and hides the toolbar", async ({ page }) => {
  await page.goto("/fixture.html");
  await selectEditWord(page);

  await toolbar(page).getByRole("button", { name: "Rewrite" }).click();
  await page.evaluate(() => window.__resolveWritingHelp({ status: "rewritten", text: "Modify" }));
  await toolbar(page).getByRole("button", { name: "Accept" }).click();

  await expect(toolbar(page)).toHaveCount(0);
  const block = page.locator('[data-anglesite-block-id="t1"]');
  await expect(block).toContainText("Modify me");
  await expect(block).not.toContainText("Edit me");
});

test("clicking Discard leaves the original text untouched and hides the toolbar", async ({ page }) => {
  await page.goto("/fixture.html");
  await selectEditWord(page);

  await toolbar(page).getByRole("button", { name: "Tighten" }).click();
  await page.evaluate(() => window.__resolveWritingHelp({ status: "rewritten", text: "Modify" }));
  await toolbar(page).getByRole("button", { name: "Discard" }).click();

  await expect(toolbar(page)).toHaveCount(0);
  const block = page.locator('[data-anglesite-block-id="t1"]');
  await expect(block).toContainText("Edit me");
});
