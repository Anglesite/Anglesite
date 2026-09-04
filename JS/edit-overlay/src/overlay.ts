// DOM behavior layer for the WKWebView edit overlay.
//
// One install per page. Mounts inline styles, wires hover / click-to-edit / image-drop, and
// installs a reply channel so native can answer edit attempts. Pure DOM manipulation — all
// JS → native messaging goes through `messages.ts`.

import { elementInfoFor } from "./selector.js";
import {
  installReplyHandler,
  nextEditID,
  postEdit,
  postGoalElementPick,
  postPlacementPick,
  type EditMessage,
  type EditReply,
} from "./messages.js";
import { showToast } from "./toast.js";
import { installVisibleElementsReporter } from "./visible-elements.js";

export const HOVER_CLASS = "anglesite-hover";
export const GOAL_PICK_HOVER_CLASS = "anglesite-goal-pick-hover";
export const EDITABLE_CLASS = "anglesite-editing";
export const IMAGE_DROP_TARGET_CLASS = "anglesite-image-drop-target";
export const IMAGE_DROP_ACTIVE_CLASS = "anglesite-image-drop-active";
export const IMAGE_DROP_HINT_ATTRIBUTE = "data-anglesite-image-drop-hint";
const INSTALLED_FLAG = "__anglesiteOverlayInstalled" as const;
const STYLE_TAG_MARKER = "data-anglesite-overlay";

// Tags whose text content is plausibly user-editable as a unit. Conservative on purpose —
// structural containers (div, body, section, header, …) don't qualify; the selector strategy
// (#18) will let us refine this once Phase 5's source patcher knows what it can resolve.
const EDITABLE_TAG = /^(H[1-6]|P|SPAN|A|LI|EM|STRONG|BLOCKQUOTE|FIGCAPTION|CAPTION|LABEL|DT|DD)$/;

function isEditableText(el: Element): boolean {
  return EDITABLE_TAG.test(el.tagName);
}

function installStyles(): void {
  if (document.head.querySelector(`style[${STYLE_TAG_MARKER}]`)) return;
  const style = document.createElement("style");
  style.setAttribute(STYLE_TAG_MARKER, "");
  style.textContent = [
    `.${HOVER_CLASS} { outline: 2px solid rgba(0, 122, 255, 0.8); outline-offset: 2px; cursor: text; }`,
    `.${EDITABLE_CLASS} { outline: 2px solid rgba(0, 122, 255, 1); outline-offset: 2px; background: rgba(0, 122, 255, 0.05); }`,
    // Distinct color from HOVER_CLASS (blue) on purpose: goal-element pick mode can hover any
    // element, including ones that also qualify for ordinary click-to-edit hover, and the two
    // modes' feedback must stay visually distinguishable.
    `.${GOAL_PICK_HOVER_CLASS} { outline: 2px dashed rgba(255, 149, 0, 0.9); outline-offset: 2px; cursor: pointer; }`,
    // !important here (unlike HOVER_CLASS/EDITABLE_CLASS above): site stylesheets commonly reset
    // `img { outline: none }`, and the drop-target ring needs to survive that.
    `.${IMAGE_DROP_TARGET_CLASS} { outline: 3px dashed rgba(0, 122, 255, 0.9) !important; outline-offset: 4px !important; filter: brightness(0.9) !important; }`,
    `.${IMAGE_DROP_ACTIVE_CLASS} { outline-style: solid !important; filter: brightness(1.05) !important; cursor: copy; }`,
    `[${IMAGE_DROP_HINT_ATTRIBUTE}] { position: fixed; z-index: 2147483647; left: 50%; top: 16px; transform: translateX(-50%); padding: 8px 12px; border-radius: 9px; background: rgba(28, 28, 30, 0.92); color: white; font: 600 13px/1.25 -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 4px 18px rgba(0, 0, 0, 0.25); pointer-events: none; }`,
  ].join("\n");
  document.head.appendChild(style);
}

function attachHover(): void {
  let hovered: Element | null = null;
  document.addEventListener("mouseover", (ev) => {
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1 || !isEditableText(target)) {
      if (hovered) { hovered.classList.remove(HOVER_CLASS); hovered = null; }
      return;
    }
    if (hovered && hovered !== target) hovered.classList.remove(HOVER_CLASS);
    target.classList.add(HOVER_CLASS);
    hovered = target;
  });
  document.addEventListener("mouseout", (ev) => {
    const target = ev.target as Element | null;
    if (target?.classList.contains(HOVER_CLASS)) target.classList.remove(HOVER_CLASS);
    if (hovered === target) hovered = null;
  });
}

function attachClickToEdit(awaitReply: (id: string, handler: (r: EditReply) => void) => void): void {
  document.addEventListener("click", (ev) => {
    const target = ev.target as HTMLElement | null;
    if (!target || target.nodeType !== 1 || !isEditableText(target)) return;
    if (target.isContentEditable) return;
    ev.preventDefault();

    target.classList.remove(HOVER_CLASS);
    // Capture the selector snapshot BEFORE any edit mutations — `textContent` (and any other
    // edit-time-mutable field) must reflect the source-file state so the server-side patcher
    // can find the element. Done after HOVER_CLASS is removed and before EDITABLE_CLASS is
    // added so the snapshot has no overlay-internal classes either.
    const originalInfo = elementInfoFor(target);
    target.contentEditable = "true";
    target.classList.add(EDITABLE_CLASS);
    target.focus();

    const originalText = target.textContent ?? "";

    // Apple Intelligence Writing Tools (#91) rides this same path with no extra wiring. Once the
    // element is `contentEditable`, WebKit offers the system Writing Tools popover (rewrite /
    // proofread / tone shift / summarize) on text selection — gated app-side by
    // `WebViewBridge.enableWritingTools` setting `writingToolsBehavior = .complete`. A Writing
    // Tools rewrite mutates `textContent` in place (WebKit applies it inline to the DOM), so the
    // blur-time diff below captures it exactly like a typed edit: one `replace-text` apply-edit,
    // one undoable commit. No new message type, and no Claude/LLM tokens.
    const finish = () => {
      target.contentEditable = "false";
      target.classList.remove(EDITABLE_CLASS);
      const newText = target.textContent ?? "";
      if (newText === originalText) return;
      const id = nextEditID();
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: originalInfo,
        op: "replace-text",
        value: newText,
      };
      const ok = postEdit(msg);
      if (!ok) {
        target.textContent = originalText;
        showToast("Not running inside the Anglesite app");
        return;
      }
      // #1851: a reply that isn't "applied" means the host never actually landed the edit (e.g.
      // the container's guest clone had fallen behind Source/'s HEAD and the persist step
      // refused it) — the DOM must not keep showing the optimistic change as if it had, mirroring
      // `attachImageDrop`'s revert-with-toast on failure.
      awaitReply(id, (reply) => {
        if (reply.status === "applied") return;
        target.textContent = originalText;
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Edit failed");
      });
    };

    target.addEventListener("blur", finish, { once: true });
  });
}

export interface PlacementPickControls {
  enter(): void;
  exit(): void;
}

/** Placement-pick mode: while active, a click on ANY element (not just EDITABLE_TAG) reports its
 *  ElementInfo via `anglesite:pick-placement` instead of the normal click-to-edit path. Entered
 *  only via an explicit native call (`window.anglesite._enterPlacementMode()`), never ambient —
 *  outside this mode, ordinary click-to-edit behavior (`attachClickToEdit`) is unaffected.
 *
 *  `active` is closure-local and resets to `false` whenever this script re-runs, which any real
 *  navigation (HMR reload, route change, ⌘R) causes. The native side can't see that happen, so it
 *  watches its own `WKNavigationDelegate` instead: `PreviewView.onPreviewNavigated` cancels an
 *  in-flight pick rather than leaving a HUD armed over a listener that no longer exists
 *  (#768 final review, Finding 8). Nothing here re-arms itself on load — arming is always an
 *  explicit native call. */
export function installPlacementPickMode(win: Window & typeof globalThis = window): PlacementPickControls {
  let active = false;

  const handler = (ev: MouseEvent) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    ev.preventDefault();
    ev.stopPropagation();
    postPlacementPick(
      {
        id: nextEditID(),
        type: "anglesite:pick-placement",
        path: location.pathname,
        selector: elementInfoFor(target),
      },
      win as unknown as Parameters<typeof postPlacementPick>[1],
    );
  };
  document.addEventListener("click", handler, { capture: true });

  const anglesiteWin = win as unknown as { anglesite?: { _enterPlacementMode?: () => void; _exitPlacementMode?: () => void } };
  anglesiteWin.anglesite = anglesiteWin.anglesite ?? {};
  const controls: PlacementPickControls = {
    enter: () => { active = true; },
    exit: () => { active = false; },
  };
  anglesiteWin.anglesite._enterPlacementMode = controls.enter;
  anglesiteWin.anglesite._exitPlacementMode = controls.exit;
  return controls;
}

export interface GoalPickControls {
  enter(): void;
  exit(): void;
}

/** Goal-element-pick mode (#1270 slice 5): while active, hovering any element outlines it and a
 *  click reports its `ElementInfo` via `anglesite:pick-goal-element` instead of the normal
 *  click-to-edit path — same exclusivity contract as `installPlacementPickMode`, entered only via
 *  an explicit native call. Adds hover feedback placement-pick mode doesn't have, since "point at
 *  the reviews section" is materially harder to do accurately with no visual confirmation of the
 *  candidate element before clicking. */
export function installGoalPickMode(win: Window & typeof globalThis = window): GoalPickControls {
  let active = false;
  let hovered: Element | null = null;

  const clearHover = () => {
    hovered?.classList.remove(GOAL_PICK_HOVER_CLASS);
    hovered = null;
  };

  document.addEventListener("mouseover", (ev) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    if (hovered && hovered !== target) hovered.classList.remove(GOAL_PICK_HOVER_CLASS);
    target.classList.add(GOAL_PICK_HOVER_CLASS);
    hovered = target;
  });
  document.addEventListener("mouseout", (ev) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (target === hovered) clearHover();
  });

  const clickHandler = (ev: MouseEvent) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    ev.preventDefault();
    ev.stopPropagation();
    clearHover();
    postGoalElementPick(
      {
        id: nextEditID(),
        type: "anglesite:pick-goal-element",
        path: location.pathname,
        selector: elementInfoFor(target),
      },
      win as unknown as Parameters<typeof postGoalElementPick>[1],
    );
  };
  document.addEventListener("click", clickHandler, { capture: true });

  const anglesiteGoalWin = win as unknown as { anglesite?: { _enterGoalPickMode?: () => void; _exitGoalPickMode?: () => void } };
  anglesiteGoalWin.anglesite = anglesiteGoalWin.anglesite ?? {};
  const controls: GoalPickControls = {
    enter: () => { active = true; },
    exit: () => { active = false; clearHover(); },
  };
  anglesiteGoalWin.anglesite._enterGoalPickMode = controls.enter;
  anglesiteGoalWin.anglesite._exitGoalPickMode = controls.exit;
  return controls;
}

function attachImageDrop(awaitReply: (id: string, handler: (r: EditReply) => void) => void): void {
  let dragIsFile = false;
  let dragDepth = 0;
  let activeTarget: HTMLImageElement | null = null;

  const imageTargets = (): HTMLImageElement[] => Array.from(document.querySelectorAll("img"));

  const isFileDrag = (dataTransfer: DataTransfer | null): boolean => {
    if (!dataTransfer) return false;
    if (Array.from(dataTransfer.types).includes("Files")) return true;
    return Array.from(dataTransfer.items).some((item) => item.kind === "file");
  };

  const setActiveTarget = (target: HTMLImageElement | null): void => {
    if (activeTarget === target) return;
    activeTarget?.classList.remove(IMAGE_DROP_ACTIVE_CLASS);
    target?.classList.add(IMAGE_DROP_ACTIVE_CLASS);
    activeTarget = target;
  };

  const showTargets = (): void => {
    const targets = imageTargets();
    for (const target of targets) target.classList.add(IMAGE_DROP_TARGET_CLASS);

    let hint = document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`) as HTMLDivElement | null;
    if (!hint) {
      hint = document.createElement("div");
      hint.setAttribute(IMAGE_DROP_HINT_ATTRIBUTE, "");
      document.body.appendChild(hint);
    }
    hint.textContent = targets.length > 0
      ? "Drop onto a highlighted image to replace it"
      : "Drop anywhere to add this page's first image";
  };

  const clearTargets = (): void => {
    setActiveTarget(null);
    for (const target of imageTargets()) target.classList.remove(IMAGE_DROP_TARGET_CLASS);
    document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.remove();
    dragIsFile = false;
    dragDepth = 0;
  };

  const imageAtEvent = (ev: DragEvent): HTMLImageElement | null => {
    const element = ev.target instanceof Element ? ev.target : null;
    return element?.closest("img") as HTMLImageElement | null;
  };

  document.addEventListener("dragenter", (ev) => {
    if (!isFileDrag(ev.dataTransfer)) return;
    // dragenter fires once per DOM element boundary the pointer crosses, not once per page
    // entry — so only rescan/highlight on the transition into a file drag, same as dragover.
    const wasFileDrag = dragIsFile;
    dragIsFile = true;
    dragDepth += 1;
    if (!wasFileDrag) showTargets();
    // Prevented here too (not just on dragover below) so WKWebView doesn't show a "not allowed"
    // cursor for the first frame of the drag, before the first dragover fires.
    ev.preventDefault();
  });
  document.addEventListener("dragover", (ev) => {
    // showTargets() re-scans the whole document, so only pay for it on the dragenter → dragover
    // transition (normally already done by dragenter; this is just the fallback for the rare case
    // where dataTransfer didn't read as a file drag until dragover). Every later dragover in the
    // same drag only needs to move the active-target highlight, not re-highlight everything.
    if (!dragIsFile) {
      if (!isFileDrag(ev.dataTransfer)) return;
      dragIsFile = true;
      showTargets();
    }
    const target = imageAtEvent(ev);
    setActiveTarget(target);
    // Prevent WKWebView from navigating to a dropped local file. A target outside an image is
    // still handled below with guidance instead of silently discarding the gesture.
    ev.preventDefault();
    // Accept the drop over a highlighted image target (replace), OR anywhere on a page with no
    // images at all (insert-first-image — see the `drop` handler's matching `!hadTargets` branch
    // below). Without the second condition, dropEffect stayed "none" for every point that isn't
    // literally over an <img>, which on an image-less page is every point on the page: the OS
    // rejects the drop outright (macOS's drag "poof back to origin" animation) and `drop` never
    // even fires, so the insert-new-image path below was unreachable from a real drag.
    const acceptsDrop = target !== null || imageTargets().length === 0;
    if (ev.dataTransfer) ev.dataTransfer.dropEffect = acceptsDrop ? "copy" : "none";
  });
  const replaceImage = (target: HTMLImageElement, file: File): void => {
    // Save originals before the optimistic swap so we can revert on failure.
    const savedSrc = target.src;
    const savedSrcset = target.getAttribute("srcset");
    const blobURL = URL.createObjectURL(file);
    target.src = blobURL;
    target.removeAttribute("srcset");

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      target.src = savedSrc;
      if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
      else target.removeAttribute("srcset");
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        target.src = reply.result.src;
        if (reply.result.srcset !== undefined) {
          target.setAttribute("srcset", reply.result.srcset);
        } else {
          target.removeAttribute("srcset");
        }
        URL.revokeObjectURL(blobURL);
      } else {
        target.src = savedSrc;
        if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
        else target.removeAttribute("srcset");
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image edit timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        selector: elementInfoFor(target),
        op: "replace-image-src",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  };

  const insertNewImage = (file: File): void => {
    const element = document.createElement("img");
    const blobURL = URL.createObjectURL(file);
    element.src = blobURL;
    document.body.appendChild(element);

    const id = nextEditID();
    let settled = false;

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      element.remove();
      URL.revokeObjectURL(blobURL);
      showToast(text);
    };

    const settleOnReply = (reply: EditReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (reply.status === "applied" && reply.result) {
        element.src = reply.result.src;
        if (reply.result.srcset !== undefined) element.setAttribute("srcset", reply.result.srcset);
        URL.revokeObjectURL(blobURL);
      } else {
        element.remove();
        URL.revokeObjectURL(blobURL);
        showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image insert failed");
      }
    };

    const timeoutHandle = setTimeout(() => {
      revertWithToast("Image insert timed out");
    }, 30_000);

    awaitReply(id, settleOnReply);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      const msg: EditMessage = {
        id,
        type: "anglesite:apply-edit",
        path: location.pathname,
        op: "insert-image",
        value: { filename: file.name, mimeType: file.type, dataURL },
      };
      const ok = postEdit(msg);
      if (!ok) {
        clearTimeout(timeoutHandle);
        revertWithToast("Not running inside the Anglesite app");
      }
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  };

  document.addEventListener("drop", (ev) => {
    const file = (ev as DragEvent).dataTransfer?.files[0];
    if (!file) {
      // dragover already recognized this as a file drag (dragIsFile true) using the always-
      // available types/items — but dataTransfer.files can still come back empty at drop time
      // for some promise-backed/multi-item drag sources. Still prevent WKWebView's default file
      // navigation and clear the stuck highlight state instead of silently discarding the drop.
      if (dragIsFile) {
        ev.preventDefault();
        clearTargets();
        showToast("Couldn't read the dropped file");
      }
      return;
    }
    ev.preventDefault();
    const target = imageAtEvent(ev as DragEvent);
    const hadTargets = imageTargets().length > 0;
    const isImageFile = file.type.startsWith("image/");
    clearTargets();

    if (!target) {
      if (!hadTargets && isImageFile) {
        insertNewImage(file);
        return;
      }
      showToast(!hadTargets
        ? "Drop an image file anywhere to add this page's first image"
        : isImageFile
          ? "Drop onto a highlighted image to replace it"
          : "Drop an image file onto a highlighted image to replace it");
      return;
    }
    if (!isImageFile) {
      showToast("Choose an image file to replace this image");
      return;
    }

    replaceImage(target, file);
  });
  document.addEventListener("dragleave", () => {
    if (!dragIsFile) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) clearTargets();
  });
  // dragend fires on the drag's source node — for a real Finder→WKWebView drag that's outside
  // this document, so this rarely fires in production. dragleave's depth counter above is the
  // real cleanup path; this is a defensive backstop (and what lets tests reset state between runs).
  document.addEventListener("dragend", clearTargets);
}

/** Mount the overlay onto `window`/`document`. Safe to call more than once. */
export function install(): void {
  const win = window as unknown as { [INSTALLED_FLAG]?: boolean };
  if (win[INSTALLED_FLAG]) return;
  win[INSTALLED_FLAG] = true;

  installStyles();
  const { awaitReply } = installReplyHandler();
  attachHover();
  attachClickToEdit(awaitReply);
  attachImageDrop(awaitReply);
  installVisibleElementsReporter();
  installPlacementPickMode(window);
  installGoalPickMode(window);
}
