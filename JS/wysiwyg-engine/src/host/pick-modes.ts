// Native-armed element pick modes on the live page: the Effects gallery's click-to-place
// (#768) and the experiment configure step's goal picker (#1518). Both report the clicked
// element's `ElementInfo` over the `wysiwyg` bridge and are entered only by an explicit native
// call (`window.anglesite._enter…Mode()`), never ambiently — outside a mode, clicks reach the
// block engine's own selection handling untouched. Moved here from the retired
// `JS/edit-overlay/src/overlay.ts` + `messages.ts` (#1957); only the bridge namespace changed.

import { elementInfoFor, type ElementInfo } from "./element-info.js";

export const GOAL_PICK_HOVER_CLASS = "anglesite-goal-pick-hover";
const STYLE_ID = "__anglesite-wysiwyg-pick-modes-style";

export interface PlacementPickMessage {
  id: string;
  type: "anglesite:pick-placement";
  path: string;
  selector: ElementInfo;
}

export interface GoalElementPickMessage {
  id: string;
  type: "anglesite:pick-goal-element";
  path: string;
  selector: ElementInfo;
}

export interface PickModeControls {
  enter(): void;
  exit(): void;
}

interface WebKitWindow {
  webkit?: { messageHandlers?: { wysiwyg?: { postMessage: (body: unknown) => void } } };
}

interface PickModeWindow extends WebKitWindow {
  anglesite?: {
    _enterPlacementMode?: () => void;
    _exitPlacementMode?: () => void;
    _enterGoalPickMode?: () => void;
    _exitGoalPickMode?: () => void;
  };
}

let messageCounter = 0;
/** Monotonic-ish per-tab message ID. Tab refresh resets the sequence; native correlates by full id. */
export function nextMessageID(): string {
  messageCounter += 1;
  return `e-${Date.now().toString(36)}-${messageCounter}`;
}

/** Posts a pick report to native. No reply is awaited — the whole match/apply flow runs natively
 *  and updates the app's own HUD/sheet, not the page. Returns `false` (no throw) when the bridge
 *  is absent. */
function post(message: PlacementPickMessage | GoalElementPickMessage, win: WebKitWindow): boolean {
  const handler = win.webkit?.messageHandlers?.wysiwyg;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}

/** Placement-pick mode: while active, a click on ANY element reports its `ElementInfo` via
 *  `anglesite:pick-placement`. `active` is closure-local and resets to `false` whenever this
 *  script re-runs, which any real navigation (HMR reload, route change, ⌘R) causes. The native
 *  side can't see that happen, so it watches its own `WKNavigationDelegate` instead:
 *  `PreviewView.onPreviewNavigated` cancels an in-flight pick rather than leaving a HUD armed
 *  over a listener that no longer exists (#768 final review, Finding 8). Nothing here re-arms
 *  itself on load — arming is always an explicit native call. */
export function installPlacementPickMode(
  win: Window & typeof globalThis = window,
  doc: Document = document,
): PickModeControls {
  let active = false;

  const handler = (event: MouseEvent) => {
    if (!active) return;
    const target = event.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    event.preventDefault();
    event.stopPropagation();
    post(
      { id: nextMessageID(), type: "anglesite:pick-placement", path: location.pathname, selector: elementInfoFor(target) },
      win as unknown as WebKitWindow,
    );
  };
  doc.addEventListener("click", handler, { capture: true });

  const pickWin = win as unknown as PickModeWindow;
  pickWin.anglesite = pickWin.anglesite ?? {};
  const controls: PickModeControls = {
    enter: () => { active = true; },
    exit: () => { active = false; },
  };
  pickWin.anglesite._enterPlacementMode = controls.enter;
  pickWin.anglesite._exitPlacementMode = controls.exit;
  return controls;
}

/** Goal-element-pick mode (#1270 slice 5): while active, hovering any element outlines it and a
 *  click reports its `ElementInfo` via `anglesite:pick-goal-element` — same exclusivity contract
 *  as `installPlacementPickMode`. Adds hover feedback placement-pick mode doesn't have, since
 *  "point at the reviews section" is materially harder to do accurately with no visual
 *  confirmation of the candidate element before clicking. The dashed orange ring is deliberately
 *  distinct from the block editor's own blue hover outline (`hover-outline.ts`), which can be
 *  showing on the same page at the same time. */
export function installGoalPickMode(
  win: Window & typeof globalThis = window,
  doc: Document = document,
): PickModeControls {
  installStyles(doc);
  let active = false;
  let hovered: Element | null = null;

  const clearHover = () => {
    hovered?.classList.remove(GOAL_PICK_HOVER_CLASS);
    hovered = null;
  };

  doc.addEventListener("mouseover", (event) => {
    if (!active) return;
    const target = event.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    if (hovered && hovered !== target) hovered.classList.remove(GOAL_PICK_HOVER_CLASS);
    target.classList.add(GOAL_PICK_HOVER_CLASS);
    hovered = target;
  });
  doc.addEventListener("mouseout", (event) => {
    if (!active) return;
    if ((event.target as Element | null) === hovered) clearHover();
  });

  const clickHandler = (event: MouseEvent) => {
    if (!active) return;
    const target = event.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    event.preventDefault();
    event.stopPropagation();
    clearHover();
    post(
      { id: nextMessageID(), type: "anglesite:pick-goal-element", path: location.pathname, selector: elementInfoFor(target) },
      win as unknown as WebKitWindow,
    );
  };
  doc.addEventListener("click", clickHandler, { capture: true });

  const pickWin = win as unknown as PickModeWindow;
  pickWin.anglesite = pickWin.anglesite ?? {};
  const controls: PickModeControls = {
    enter: () => { active = true; },
    exit: () => { active = false; clearHover(); },
  };
  pickWin.anglesite._enterGoalPickMode = controls.enter;
  pickWin.anglesite._exitGoalPickMode = controls.exit;
  return controls;
}

function installStyles(doc: Document): void {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElement("style");
  style.id = STYLE_ID;
  style.textContent =
    `.${GOAL_PICK_HOVER_CLASS} { outline: 2px dashed rgba(255, 149, 0, 0.9); outline-offset: 2px; cursor: pointer; }`;
  doc.head.appendChild(style);
}
