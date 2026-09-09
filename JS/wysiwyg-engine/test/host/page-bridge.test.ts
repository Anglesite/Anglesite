// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { installPageBridge } from "../../src/host/page-bridge.js";

function setPath(path: string) {
  window.history.replaceState({}, "", path);
}

/**
 * The always-on half of the injected bundle (#1957): what used to be the retired overlay's
 * `index.ts` boot — harness pages get the component canvas, every other page gets the Siri
 * visible-elements reporter and the two native-armed pick modes.
 */
describe("page bridge boot", () => {
  beforeEach(() => {
    delete (window as any).__anglesitePageBridgeInstalled;
    delete (window as any).__anglesiteComponentCanvasInstalled;
    delete (window as any).__anglesiteVisibleElementsInstalled;
    delete (window as any).anglesiteCanvas;
    delete (window as any).anglesite;
  });

  it("installs the component canvas, and only that, on a harness page", () => {
    setPath("/_anglesite/component/Card");
    installPageBridge();
    expect((window as any).anglesiteCanvas).toBeDefined();
    expect((window as any).anglesite).toBeUndefined();
  });

  it("installs the pick modes (and the visible-elements reporter) on an ordinary page", () => {
    setPath("/about/");
    installPageBridge();
    expect((window as any).anglesiteCanvas).toBeUndefined();
    expect(typeof (window as any).anglesite._enterPlacementMode).toBe("function");
    expect(typeof (window as any).anglesite._enterGoalPickMode).toBe("function");
  });

  it("is idempotent per window", () => {
    setPath("/about/");
    installPageBridge();
    const first = (window as any).anglesite._enterPlacementMode;
    installPageBridge();
    expect((window as any).anglesite._enterPlacementMode).toBe(first);
  });
});
