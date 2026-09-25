// The always-on half of the injected bundle (#1957): everything the page reports to native
// regardless of whether a block engine is mounted. `mount.ts` boots this once per page load —
// the retired `JS/edit-overlay/src/index.ts` used to.
//
// Component-harness pages (`/_anglesite/component/*`) get the read-only canvas
// (`component-canvas.ts`) instead of the page-level reporters: the Component Editor drives that
// canvas from native and never mounts a block engine there.

import { installComponentCanvas, isHarnessPage } from "./component-canvas.js";
import { installGoalPickMode, installPlacementPickMode } from "./pick-modes.js";
import { installVisibleElementsReporter } from "./visible-elements.js";

const INSTALLED_FLAG = "__anglesitePageBridgeInstalled" as const;

/** Installs the page-level reporters (or the harness canvas). Idempotent per window. */
export function installPageBridge(win: Window & typeof globalThis = window): void {
  const flagged = win as unknown as { [INSTALLED_FLAG]?: boolean };
  if (flagged[INSTALLED_FLAG]) return;
  flagged[INSTALLED_FLAG] = true;

  if (isHarnessPage()) {
    installComponentCanvas();
    return;
  }
  installVisibleElementsReporter();
  installPlacementPickMode(win);
  installGoalPickMode(win);
}

/** Runs `installPageBridge` once the DOM is parsed. The bundle is injected at `atDocumentEnd`,
 *  so the document is usually already past `loading` — fall through to immediate install then. */
export function bootPageBridge(win: Window & typeof globalThis = window): void {
  if (win.document.readyState === "loading") {
    win.document.addEventListener("DOMContentLoaded", () => installPageBridge(win), { once: true });
  } else {
    installPageBridge(win);
  }
}
