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

test("hitTestFrame resolves a real point inside a frame to the block under it", async ({ page }) => {
  // The only positive-path coverage of hitTestFrame at any tier: jsdom has no layout engine, so
  // test/breakpoints.test.ts can only prove the unregistered-name -> null case.
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  // Measured *inside* the frame, so these are the frame's own viewport coordinates — which is what
  // hitTestFrame's `point` means (its elementFromPoint runs against the frame document).
  const point = await page
    .frameLocator("#phone")
    .locator('[data-anglesite-block-id="b1"]')
    .evaluate((el) => {
      const rect = el.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    });

  expect(await page.evaluate((pt) => window.__canvas.hitTestFrame("phone", pt), point)).toBe("b1");
  expect(await page.evaluate((pt) => window.__canvas.hitTestFrame("nope", pt), point)).toBeNull();
});

test("RichTextEditor edits a block element belonging to a frame's document", async ({ page }) => {
  // enter()'s element guard and the format commands' Selection/Range lookups both have to resolve
  // against the *frame's* realm and document, not the one this module was loaded in.
  await page.goto("/breakpoints-fixture.html");
  await page.waitForFunction(() => document.title === "breakpoints:ready");

  expect(await page.evaluate(() => window.__enterRichTextInFrame("phone", "t1"))).toBe("t1");

  await page
    .frameLocator("#phone")
    .locator('[data-anglesite-block-id="t1"]')
    .evaluate((el) => {
      const textNode = el.firstChild;
      if (!textNode) throw new Error("expected a text node");
      const range = el.ownerDocument.createRange();
      range.setStart(textNode, 0);
      range.setEnd(textNode, 4); // "Edit" (of "Edit me")
      const selection = el.ownerDocument.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
    });

  await page.evaluate(() => window.__toggleFormat("strong"));
  await page.evaluate(() => window.__richText.exit());
  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([
    { kind: "strong", text: "Edit" },
    { kind: "text", text: " me" },
  ]);
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
