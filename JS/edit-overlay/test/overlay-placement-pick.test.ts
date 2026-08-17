// @vitest-environment jsdom
//
// Isolated from overlay.test.ts on purpose: that file's `beforeAll` calls the full `install()`
// (attachClickToEdit et al.) once for its whole suite, which would make the "does not interfere
// with EDITABLE_TAG click-to-edit" case below meaningless — click-to-edit would already be wired
// up for reasons unrelated to installPlacementPickMode. Vitest gives each test file its own jsdom
// `window`, so a separate file is real isolation, not just a different describe block.
import { describe, it, expect } from "vitest";
import { installPlacementPickMode } from "../src/overlay.js";

function makeWin() {
  const posted: unknown[] = [];
  const win = {
    webkit: { messageHandlers: { anglesite: { postMessage: (body: unknown) => posted.push(body) } } },
  } as unknown as Window & typeof globalThis;
  return { win, posted };
}

describe("placement-pick mode", () => {
  it("does nothing on click when not in placement mode", () => {
    document.body.innerHTML = `<div id="target">hi</div>`;
    const { win, posted } = makeWin();
    installPlacementPickMode(win);
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(0);
  });

  it("reports a click on any element while in placement mode, then stops after exit", () => {
    document.body.innerHTML = `<div id="target">hi</div>`;
    const { win, posted } = makeWin();
    const controls = installPlacementPickMode(win);
    controls.enter();
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
    expect((posted[0] as { type: string }).type).toBe("anglesite:pick-placement");
    expect((posted[0] as { selector: { tag: string } }).selector.tag).toBe("DIV");

    controls.exit();
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1); // no new post after exit
  });

  it("does not interfere with EDITABLE_TAG click-to-edit outside placement mode", () => {
    document.body.innerHTML = `<p id="p">edit me</p>`;
    const { win } = makeWin();
    installPlacementPickMode(win);
    const p = document.getElementById("p") as HTMLElement;
    p.click();
    // jsdom's `isContentEditable` getter returns `undefined` (not `false`) for a plain element —
    // `toBeFalsy()` tolerates that while still catching a real leak (attachClickToEdit isn't
    // installed by this helper; this just confirms no placement-mode side effect turned it on).
    expect(p.isContentEditable).toBeFalsy();
  });
});
