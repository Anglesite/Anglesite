// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { installGoalPickMode, GOAL_PICK_HOVER_CLASS } from "../src/overlay.js";

describe("installGoalPickMode", () => {
  beforeEach(() => {
    document.body.innerHTML = `<section id="reviews"><p>Great product</p></section>`;
  });

  it("does nothing on click before enter() is called", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    installGoalPickMode(win);
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("posts anglesite:pick-goal-element for the clicked element while active", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(1);
    expect((posted[0] as any).type).toBe("anglesite:pick-goal-element");
    expect((posted[0] as any).selector.tag).toBe("P");
  });

  it("stops posting after exit()", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    controls.exit();
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("adds a hover outline class to the candidate element while active, and clears it on mouseout", () => {
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: vi.fn() } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    const p = document.querySelector("p")!;
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(true);
    p.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(false);
  });

  it("exposes window.anglesite._enterGoalPickMode/_exitGoalPickMode", () => {
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: vi.fn() } } } } as any;
    installGoalPickMode(win);
    expect(typeof win.anglesite._enterGoalPickMode).toBe("function");
    expect(typeof win.anglesite._exitGoalPickMode).toBe("function");
  });
});
