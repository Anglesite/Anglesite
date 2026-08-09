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

  // No explicit exit()/flush() here — toggleFormat() must commit on its own, immediately, per the
  // documented contract (design doc §4: "immediately on blur, Escape, or a format command").
  await page.evaluate(() => window.__toggleFormat("strong"));
  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([
    { kind: "strong", text: "Edit" },
    { kind: "text", text: " " },
    { kind: "strong", text: "me" },
  ]);
});

test("toggling italic on a selection already inside bold nests the formats — composition survives commit", async ({
  page,
}) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.evaluate((el) => {
    const strong = el.querySelector("strong");
    const textNode = strong?.firstChild;
    if (!strong || !textNode) throw new Error("expected an existing <strong> with a text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 1); // "m" (of "me")
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });

  await page.evaluate(() => window.__toggleFormat("em"));
  await page.waitForFunction(() => document.title === "event:applied");

  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs).toEqual([
    { kind: "text", text: "Edit " },
    {
      kind: "strong",
      text: "me",
      children: [
        { kind: "em", text: "m" },
        { kind: "text", text: "e" },
      ],
    },
  ]);
});

test("a link run's href cannot break out of the rendered href attribute", async ({ page }) => {
  // setLinkFormat can now put a host-supplied href into a real `link` run, so the fixture's
  // runs-to-markup projection interpolates it into an href="…" attribute for real — the escaper
  // has to cover `"` and not just `<`/`&`.
  await page.goto("/fixture.html");
  await page.evaluate(() =>
    window.__engine.submit({
      kind: "editText",
      blockId: "t1",
      runs: [{ kind: "link", text: "click", href: 'https://example.com/" onmouseover="boom' }],
      previousRuns: [
        { kind: "text", text: "Edit " },
        { kind: "strong", text: "me" },
      ],
    }),
  );
  await page.waitForFunction(() => document.title === "event:applied");

  const anchor = page.locator('[data-anglesite-block-id="t1"] a');
  await expect(anchor).toHaveAttribute("href", 'https://example.com/" onmouseover="boom');
  expect(await anchor.evaluate((el) => el.hasAttribute("onmouseover"))).toBe(false);
});

test("exiting without any change does not submit a no-op editText", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  await page.evaluate(() => window.__richText.exit());

  // No typing happened, so nothing should have committed — the title (flipped only by engine
  // events) stays at its initial, pre-any-event value. Wait comfortably past the fixture's 300ms
  // debounce: a regression that merely failed to *cancel* a pending commit would still look clean
  // at t+100ms and only fire afterwards.
  await page.waitForTimeout(500);
  expect(await page.title()).toBe("WYSIWYG engine fixture");
});
