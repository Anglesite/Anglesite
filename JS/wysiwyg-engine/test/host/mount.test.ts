// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
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
    delete (window as any).__anglesiteWysiwygQualityGates;
    delete (window as any).__anglesiteWysiwygKeyboardNav;
    delete (window as any).__anglesiteWysiwygAccessibility;
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

  /**
   * #1225 final-review round 2, Finding B: a `WKNavigationDelegate` now remounts on every
   * navigation completion while edit mode is on (`PreviewView.Coordinator.webView(_:didFinish:)`),
   * so `mount()` can be asked to mount a second time without an intervening `unmount()` call (e.g.
   * a native-side call racing the navigation-driven one). Without disposing the first engine first,
   * two `WysiwygEngine`/`RichTextEditor` pairs would both end up wired to the same DOM and both
   * listening for the same events. This proves `mount()` disposes whatever was previously mounted
   * before constructing the new instance — not just that the global pointer moved on (the
   * "replaces the previous engine instance" test above already covered that).
   */
  it("mount() without an intervening unmount() disposes the previous engine first", () => {
    const first = window.__anglesiteWysiwygMount!.mount(model);
    const disposeSpy = vi.spyOn(first, "dispose");

    window.__anglesiteWysiwygMount!.mount({ ...model, version: "v1" });

    expect(disposeSpy).toHaveBeenCalledOnce();
  });

  it("mount() constructs quality-gate chips wired to the same transport as the engine", () => {
    window.__anglesiteWysiwygMount!.mount(model);

    expect(window.__anglesiteWysiwygQualityGates).toBeDefined();
  });

  it("unmount() disposes the quality-gate chips and clears the global", () => {
    window.__anglesiteWysiwygMount!.mount(model);
    const chips = window.__anglesiteWysiwygQualityGates!;
    const disposeSpy = vi.spyOn(chips, "dispose");

    window.__anglesiteWysiwygMount!.unmount();

    expect(disposeSpy).toHaveBeenCalledOnce();
    expect(window.__anglesiteWysiwygQualityGates).toBeUndefined();
  });

  it("mount() constructs KeyboardNavigation and AccessibilityAnnotator", () => {
    window.__anglesiteWysiwygMount!.mount(model, {});
    expect(window.__anglesiteWysiwygKeyboardNav).toBeDefined();
    expect(window.__anglesiteWysiwygAccessibility).toBeDefined();
  });

  it("unmount() disposes and clears the keyboard-nav and accessibility globals too", () => {
    window.__anglesiteWysiwygMount!.mount(model, {});
    window.__anglesiteWysiwygMount!.unmount();
    expect(window.__anglesiteWysiwygKeyboardNav).toBeUndefined();
    expect(window.__anglesiteWysiwygAccessibility).toBeUndefined();
  });

  it("mount() posts a selection-changed message when the engine's selection changes", () => {
    const postMessage = vi.fn();
    window.webkit = { messageHandlers: { wysiwyg: { postMessage } } };

    const engine = window.__anglesiteWysiwygMount!.mount(model, {});
    engine.selection.select(null); // no-op (already null) — proves the listener doesn't fire spuriously
    expect(postMessage).not.toHaveBeenCalled();

    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    engine.selection.select("b1");
    expect(postMessage).toHaveBeenCalledWith({ type: "selection-changed", blockId: "b1" });

    delete (window as any).webkit;
  });

  it("mount() posts a focus-inspector message when Tab/Shift-Tab is pressed with a block selected (#1616)", () => {
    const postMessage = vi.fn();
    window.webkit = { messageHandlers: { wysiwyg: { postMessage } } };
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;

    const engine = window.__anglesiteWysiwygMount!.mount(model, {});
    engine.selection.select("b1");
    postMessage.mockClear();

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    expect(postMessage).toHaveBeenCalledWith({ type: "focus-inspector", direction: "forward", blockId: "b1" });

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true }));
    expect(postMessage).toHaveBeenCalledWith({ type: "focus-inspector", direction: "backward", blockId: "b1" });

    delete (window as any).webkit;
  });

  /**
   * #1589 final review, Fix 5: `WYSIWYGBlockContextMenu` (native, Swift) sets
   * `controller.selectedBlockId` directly on right-click, but nothing told `engine.selection` about
   * it — so a subsequent arrow-key press computed from JS's own (possibly stale) selection and could
   * silently relocate the user's selection to a different block. The `contextmenu` listener in
   * mount.ts must now also call `engine.selection.select(blockId)` before posting its message.
   *
   * jsdom has no layout engine, so `Document#elementFromPoint` always returns null (see
   * hit-test.test.ts) — there's no way to land a real `contextmenu` event on a point and have
   * `engine.hitTest()` resolve it naturally. Following that file's own documented workaround, stub
   * `elementFromPoint` directly so `hitTest()` resolves to the fixture block.
   */
  /**
   * #1700: restores native's `selectedBlockId` into the freshly-mounted engine's `SelectionState`.
   * Without this, a real navigation (an HMR reload, ⌘R, a route change) — which discards the
   * previous engine and mounts a brand new one with an empty selection — would silently drop the
   * selection `WYSIWYGCanvasController.insertBlockAndSelect` (#1697/#1698) pushed into the engine
   * that existed a moment before the reload, leaving the canvas unselected even though native still
   * thinks a block is selected.
   */
  it("mount() restores the given selectedBlockId into the fresh engine's selection", () => {
    const oneBlockModel: BlockModel = {
      path: "src/pages/index.astro",
      version: "v0",
      rootIds: ["b1"],
      blocks: { b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] } },
    };

    const engine = window.__anglesiteWysiwygMount!.mount(oneBlockModel, {}, "b1");

    expect(engine.selection.current).toBe("b1");
  });

  it("mount() with no selectedBlockId argument leaves the fresh engine unselected", () => {
    const engine = window.__anglesiteWysiwygMount!.mount(model, {});

    expect(engine.selection.current).toBeNull();
  });

  it("contextmenu updates engine.selection to the right-clicked block", () => {
    const oneBlockModel: BlockModel = {
      path: "src/pages/index.astro",
      version: "v0",
      rootIds: ["b1"],
      blocks: { b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] } },
    };
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const el = document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement;
    document.elementFromPoint = vi.fn().mockReturnValue(el);

    const engine = window.__anglesiteWysiwygMount!.mount(oneBlockModel, {});
    expect(engine.selection.current).toBeNull();

    el.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }));

    expect(engine.selection.current).toBe("b1");
  });
});
