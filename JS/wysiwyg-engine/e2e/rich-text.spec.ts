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

test("Add Link… holds the session while focus is in the URL field, then links the held selection (#2216)", async ({
  page,
}) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));

  const context = await page.evaluate(() => {
    const block = document.querySelector('[data-anglesite-block-id="t1"]');
    const textNode = block?.firstChild;
    if (!textNode) throw new Error("expected a text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 4); // "Edit"
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(range);
    return window.__richText.beginLinkEdit();
  });
  expect(context?.text).toBe("Edit");
  expect(context?.rect.width).toBeGreaterThan(0);

  // Stand-in for the native popover's field: real focus leaves the contenteditable block.
  await page.evaluate(() => {
    const field = document.createElement("input");
    document.body.appendChild(field);
    field.focus();
  });
  await page.waitForTimeout(400); // past the 200 ms blur-exit delay
  expect(await page.evaluate(() => window.__richText.activeBlockId)).toBe("t1");

  expect(await page.evaluate(() => window.__richText.commitLinkEdit("example.com"))).toBe("applied");
  await page.waitForFunction(() => document.title === "event:applied");
  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs?.[0]).toEqual({ kind: "link", text: "Edit", href: "https://example.com" });
});

test("without a hold, focus that really leaves ends the session after the blur delay (#2216)", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  await page.evaluate(() => {
    const field = document.createElement("input");
    document.body.appendChild(field);
    field.focus();
  });
  expect(await page.evaluate(() => window.__richText.activeBlockId)).toBe("t1");
  await page.waitForFunction(() => window.__richText.activeBlockId === null);
});

test("updating a link's address from a caret inside it keeps the link (#2223 review)", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  const result = await page.evaluate(() => {
    const block = document.querySelector('[data-anglesite-block-id="t1"]');
    const textNode = block?.firstChild;
    if (!block || !textNode) throw new Error("expected a text node");
    // Make "Edit" a link first, then put the caret inside it.
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 4);
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(range);
    window.__richText.beginLinkEdit();
    window.__richText.commitLinkEdit("/old");
    const linkText = block.querySelector("a")?.firstChild;
    if (!linkText) throw new Error("expected a link");
    const caret = document.createRange();
    caret.setStart(linkText, 2);
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(caret);
    const context = window.__richText.beginLinkEdit();
    return { context, commit: window.__richText.commitLinkEdit("/new"), html: block.innerHTML };
  });
  expect(result.context?.href).toBe("/old");
  expect(result.commit).toBe("applied");
  expect(result.html).toContain('<a href="/new">Edit</a>');
});

test("a debounced commit landing while the popover is open doesn't drop the link (#2223 review)", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__richText.enter("t1"));
  const block = page.locator('[data-anglesite-block-id="t1"]');
  await block.press("End");
  await block.pressSequentially(" word");
  await page.evaluate(() => {
    const el = document.querySelector('[data-anglesite-block-id="t1"]');
    if (!el) throw new Error("expected the block");
    // The typed text lands wherever the caret was, possibly inside the trailing <strong>.
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let text: Text | null = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if ((node as Text).data.endsWith("word")) text = node as Text;
    }
    if (!text) throw new Error("expected the typed word");
    const range = document.createRange();
    range.setStart(text, text.data.length - 4);
    range.setEnd(text, text.data.length);
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(range);
    if (window.__richText.beginLinkEdit()?.text !== "word") throw new Error("expected 'word' held");
  });
  await page.waitForFunction(() => document.title === "event:applied"); // the debounced editText
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => window.__richText.commitLinkEdit("example.com"))).toBe("applied");
  await page.waitForFunction(() =>
    JSON.stringify(window.__engine.modelSync.getBlock("t1")?.richText).includes('"href":"https://example.com"'));
  // The typed word sits inside <strong>, so the link is a nested run. (The fixture's renderer
  // draws only top-level runs, so assert on the model, not the re-rendered DOM.)
  const runs = await page.evaluate(() => window.__engine.modelSync.getBlock("t1")?.richText);
  expect(runs?.[1]?.children).toContainEqual({ kind: "link", text: "word", href: "https://example.com" });
});
