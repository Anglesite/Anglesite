import { test, expect } from "@playwright/test";

test("a real pointer drag reorders blocks via DragReorderController", async ({ page }) => {
  await page.goto("/fixture.html");
  const b1Box = await page.locator('[data-anglesite-block-id="b1"]').boundingBox();
  const b2Box = await page.locator('[data-anglesite-block-id="b2"]').boundingBox();
  if (!b1Box || !b2Box) throw new Error("expected bounding boxes");

  await page.mouse.move(b2Box.x + b2Box.width / 2, b2Box.y + b2Box.height / 2);
  await page.mouse.down();
  await page.mouse.move(b1Box.x + b1Box.width / 2, b1Box.y + 1, { steps: 5 });
  await page.mouse.up();

  await page.waitForFunction(() => document.title === "event:applied");

  const order = await page.evaluate(() => window.__engine.modelSync.current.rootIds);
  expect(order.indexOf("b2")).toBeLessThan(order.indexOf("b1"));
});

test("submitDrop inserts a new block at the given target", async ({ page }) => {
  await page.goto("/fixture.html");
  const result = await page.evaluate(() =>
    window.__submitDrop(
      { parentId: "__root__", slot: "default", index: 0 },
      { kind: "astro", componentName: "Newsletter", props: {}, slots: {}, sourceSpan: [0, 0] },
    ),
  );
  expect(result.status).toBe("applied");

  const firstId = await page.evaluate(() => window.__engine.modelSync.current.rootIds[0]);
  const firstName = await page.evaluate(
    (id) => (id ? window.__engine.modelSync.getBlock(id)?.componentName : undefined),
    firstId,
  );
  expect(firstName).toBe("Newsletter");
});

test("an external drop (palette-style payload) inserts a block via wireExternalDrop", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const dataTransfer = new DataTransfer();
    dataTransfer.setData(
      "application/x-anglesite-block",
      JSON.stringify({ kind: "astro", componentName: "CallToAction", props: {}, slots: {}, sourceSpan: [0, 0] }),
    );
    const rect = canvasEl.getBoundingClientRect();
    const dropEvent = new DragEvent("drop", {
      clientX: rect.x + 5,
      clientY: rect.y + 5,
      bubbles: true,
      cancelable: true,
      dataTransfer,
    });
    canvasEl.dispatchEvent(dropEvent);
  });

  await page.waitForFunction(() => document.title === "event:applied");
  const componentNames = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNames).toContain("CallToAction");
});

test("dragover computes a drop-target indicator; dragleave clears it", async ({ page }) => {
  // Task 7 shipped wireExternalDrop with zero unit tests (DragEvent/DataTransfer are
  // unconstructable under this project's pinned jsdom) — this is the only test covering its
  // dragover/dragleave indicator behavior at any tier.
  await page.goto("/fixture.html");
  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const rect = canvasEl.getBoundingClientRect();
    canvasEl.dispatchEvent(
      new DragEvent("dragover", { clientX: rect.x + 5, clientY: rect.y + 5, bubbles: true, cancelable: true }),
    );
  });

  const indicatorAfterDragover = await page.evaluate(() => window.__dropIndicator);
  expect(indicatorAfterDragover).not.toBeNull();
  expect(indicatorAfterDragover?.parentId).toBe("__root__");

  await page.evaluate(() => {
    document.getElementById("canvas")?.dispatchEvent(new DragEvent("dragleave", { bubbles: true }));
  });
  const indicatorAfterDragleave = await page.evaluate(() => window.__dropIndicator);
  expect(indicatorAfterDragleave).toBeNull();
});

test("the disposer stops wireExternalDrop from responding to further drags", async ({ page }) => {
  // The other half of Task 7's deferred coverage: the disposer itself has no test at any tier
  // otherwise.
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__disposeExternalDrop());

  const componentNamesBefore = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );

  await page.evaluate(() => {
    const canvasEl = document.getElementById("canvas");
    if (!canvasEl) throw new Error("missing #canvas");
    const dataTransfer = new DataTransfer();
    dataTransfer.setData(
      "application/x-anglesite-block",
      JSON.stringify({ kind: "astro", componentName: "ShouldNeverAppear", props: {}, slots: {}, sourceSpan: [0, 0] }),
    );
    const rect = canvasEl.getBoundingClientRect();
    canvasEl.dispatchEvent(
      new DragEvent("drop", { clientX: rect.x + 5, clientY: rect.y + 5, bubbles: true, cancelable: true, dataTransfer }),
    );
  });

  // Disposed listeners never run, so no engine event fires and there's nothing to await — give
  // any errant async work one beat to have shown up, then assert nothing changed.
  await page.waitForTimeout(100);
  const componentNamesAfter = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNamesAfter).toEqual(componentNamesBefore);
});

test("a version-mismatch rejection during a drop is visible and applies nothing", async ({ page }) => {
  await page.goto("/fixture.html");
  await page.evaluate(() => window.__host.forceReject("version-mismatch", "stale"));

  const result = await page.evaluate(() =>
    window.__submitDrop(
      { parentId: "__root__", slot: "default", index: 0 },
      { kind: "astro", componentName: "ShouldNotAppear", props: {}, slots: {}, sourceSpan: [0, 0] },
    ),
  );
  expect(result.status).toBe("rejected");

  const componentNames = await page.evaluate(() =>
    Object.values(window.__engine.modelSync.current.blocks).map((b) => b.componentName),
  );
  expect(componentNames).not.toContain("ShouldNotAppear");
});
