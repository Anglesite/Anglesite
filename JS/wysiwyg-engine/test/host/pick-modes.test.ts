// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { installGoalPickMode, installPlacementPickMode, GOAL_PICK_HOVER_CLASS } from "../../src/host/pick-modes.js";

function makeWin() {
  const posted: unknown[] = [];
  const win = {
    webkit: { messageHandlers: { wysiwyg: { postMessage: (body: unknown) => posted.push(body) } } },
  } as unknown as Window & typeof globalThis;
  return { win, posted };
}

/** Each test gets its own document so listener attachments never accumulate across tests. */
function freshDocument(html: string): Document {
  const doc = document.implementation.createHTMLDocument("pick");
  doc.body.innerHTML = html;
  return doc;
}

/**
 * Ported from the retired `JS/edit-overlay/test/overlay-placement-pick.test.ts` and
 * `overlay-goal-pick.test.ts` (#1957): the two native-armed pick modes, now posting on the
 * `wysiwyg` bridge.
 */
describe("placement-pick mode", () => {
  it("does nothing on click when not in placement mode", () => {
    const doc = freshDocument(`<div id="target">hi</div>`);
    const { win, posted } = makeWin();
    installPlacementPickMode(win, doc);
    (doc.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(0);
  });

  it("reports a click on any element while in placement mode, then stops after exit", () => {
    const doc = freshDocument(`<div id="target">hi</div>`);
    const { win, posted } = makeWin();
    const controls = installPlacementPickMode(win, doc);
    controls.enter();
    (doc.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
    expect((posted[0] as { type: string }).type).toBe("anglesite:pick-placement");
    expect((posted[0] as { selector: { tag: string } }).selector.tag).toBe("DIV");

    controls.exit();
    (doc.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
  });

  it("swallows the click while active so the block engine's own selection handling never sees it", () => {
    const doc = freshDocument(`<div id="target">hi</div>`);
    const { win } = makeWin();
    const controls = installPlacementPickMode(win, doc);
    controls.enter();
    const bubbled = vi.fn();
    doc.addEventListener("click", bubbled);
    (doc.getElementById("target") as HTMLElement).click();
    expect(bubbled).not.toHaveBeenCalled();
  });

  it("exposes window.anglesite._enterPlacementMode/_exitPlacementMode for native", () => {
    const doc = freshDocument(`<div id="target">hi</div>`);
    const { win, posted } = makeWin();
    installPlacementPickMode(win, doc);
    const hooks = (win as unknown as { anglesite: { _enterPlacementMode: () => void; _exitPlacementMode: () => void } }).anglesite;
    hooks._enterPlacementMode();
    (doc.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
    hooks._exitPlacementMode();
    (doc.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
  });
});

describe("goal-pick mode", () => {
  let doc: Document;

  beforeEach(() => {
    doc = freshDocument(`<section id="reviews"><p>Great product</p></section>`);
  });

  it("does nothing on click before enter() is called", () => {
    const { win, posted } = makeWin();
    installGoalPickMode(win, doc);
    doc.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("posts anglesite:pick-goal-element for the clicked element while active", () => {
    const { win, posted } = makeWin();
    const controls = installGoalPickMode(win, doc);
    controls.enter();
    doc.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(1);
    expect((posted[0] as { type: string }).type).toBe("anglesite:pick-goal-element");
    expect((posted[0] as { selector: { tag: string } }).selector.tag).toBe("P");
  });

  it("stops posting after exit()", () => {
    const { win, posted } = makeWin();
    const controls = installGoalPickMode(win, doc);
    controls.enter();
    controls.exit();
    doc.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("adds a hover outline class to the candidate element while active, and clears it on mouseout", () => {
    const { win } = makeWin();
    const controls = installGoalPickMode(win, doc);
    controls.enter();
    const p = doc.querySelector("p")!;
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(true);
    p.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(false);
  });

  it("does not outline anything while inactive", () => {
    const { win } = makeWin();
    installGoalPickMode(win, doc);
    const p = doc.querySelector("p")!;
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(false);
  });

  it("exposes window.anglesite._enterGoalPickMode/_exitGoalPickMode", () => {
    const { win } = makeWin();
    installGoalPickMode(win, doc);
    const hooks = (win as unknown as { anglesite: Record<string, unknown> }).anglesite;
    expect(typeof hooks._enterGoalPickMode).toBe("function");
    expect(typeof hooks._exitGoalPickMode).toBe("function");
  });

  it("shares window.anglesite with placement-pick mode instead of clobbering it", () => {
    const { win } = makeWin();
    installPlacementPickMode(win, doc);
    installGoalPickMode(win, doc);
    const hooks = (win as unknown as { anglesite: Record<string, unknown> }).anglesite;
    expect(typeof hooks._enterPlacementMode).toBe("function");
    expect(typeof hooks._enterGoalPickMode).toBe("function");
  });
});
