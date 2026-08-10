// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import type { BlockModel } from "../../src/types.js";
import "../../src/host/mount.js";

/**
 * `window.__anglesiteWysiwygMount` (#1225 final-review fix wave, Finding 1): the entry point the
 * Swift host's `WYSIWYGCanvasController.mountEngine()`/`unmountEngine()` calls via
 * `evaluateJavaScript`. Before this fix wave nothing on the Swift side ever called `mount()`, so
 * this file only proves the JS half of the contract works — the actual `evaluateJavaScript` call
 * isn't exercisable from `swift test` (no real `WKWebView`); see
 * `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`'s `mountScript`/`unmountScript`
 * tests for the Swift-side JS-string-construction coverage, and the app build for end-to-end proof
 * the two sides actually wire together.
 */
describe("wysiwyg engine host mount entry point (#1225)", () => {
  const model: BlockModel = { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };

  beforeEach(() => {
    document.body.innerHTML = "";
    delete (window as any).__anglesiteWysiwygEngine;
    delete (window as any).__anglesiteWysiwygRichTextEditor;
    delete (window as any).__anglesiteWysiwygHost;
  });

  it("mount() constructs the engine and rich-text editor and exposes both globally", () => {
    const engine = window.__anglesiteWysiwygMount!.mount(model);

    expect(window.__anglesiteWysiwygEngine).toBe(engine);
    expect(window.__anglesiteWysiwygRichTextEditor).toBeDefined();
  });

  it("unmount() disposes and clears both globals", () => {
    window.__anglesiteWysiwygMount!.mount(model);
    expect(window.__anglesiteWysiwygEngine).toBeDefined();
    expect(window.__anglesiteWysiwygRichTextEditor).toBeDefined();

    window.__anglesiteWysiwygMount!.unmount();

    expect(window.__anglesiteWysiwygEngine).toBeUndefined();
    expect(window.__anglesiteWysiwygRichTextEditor).toBeUndefined();
  });

  it("unmount() before any mount() is a safe no-op", () => {
    expect(() => window.__anglesiteWysiwygMount!.unmount()).not.toThrow();
  });

  it("re-mounting replaces the previous engine instance", () => {
    const first = window.__anglesiteWysiwygMount!.mount(model);
    const second = window.__anglesiteWysiwygMount!.mount({ ...model, version: "v1" });

    expect(second).not.toBe(first);
    expect(window.__anglesiteWysiwygEngine).toBe(second);
  });
});
