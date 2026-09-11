// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { showToast, TOAST_CLASS } from "../../src/host/toast.js";

describe("showToast", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
  });

  it("mounts a toast element with the given text", () => {
    showToast("Hello toast");
    const el = document.querySelector(`.${TOAST_CLASS}`);
    expect(el).toBeTruthy();
    expect(el?.textContent).toBe("Hello toast");
  });

  it("auto-dismisses after the default 4 seconds", () => {
    showToast("bye");
    expect(document.querySelector(`.${TOAST_CLASS}`)).toBeTruthy();
    vi.advanceTimersByTime(4000);
    expect(document.querySelector(`.${TOAST_CLASS}`)).toBeNull();
  });

  it("stacks: a second showToast appends another element", () => {
    showToast("one");
    showToast("two");
    expect(document.querySelectorAll(`.${TOAST_CLASS}`).length).toBe(2);
  });
});
