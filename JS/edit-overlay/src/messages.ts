// Typed wrapper around the JS → native message bridge.
//
// The native side is `AnglesiteBridge.AnglesiteScriptHandler` (registered under
// `WebViewBridge.scriptMessageNamespace = "anglesite"`). We post via the standard
// `window.webkit.messageHandlers.anglesite.postMessage(...)` channel and receive replies
// on `window.anglesite._handleReply(...)`.

import type { ElementInfo } from "./selector.js";

export interface EditMessage {
  id: string;
  type: "anglesite:apply-edit";
  path: string;
  /** Structured element metadata; the server resolves it to a CSS selector via
   *  `selector.mjs.buildSelector(info)` (decided in #18). Absent for `insert-image` — it always
   *  targets the page's content root, resolved server-side; every other op still sets it. */
  selector?: ElementInfo;
  op: string;
  value?: unknown;
}

export interface EditReply {
  id: string;
  status: "applied" | "failed" | "ambiguous";
  message?: string;
  /** Op-scoped metadata. For `replace-image-src`, carries the final src + optional
   *  srcset the overlay should apply on swap. */
  result?: { src: string; srcset?: string };
  /** Failure detail forwarded from the server (e.g. the sharp error message). */
  detail?: string;
  /** Failure reason forwarded from the server's EDIT_FAILED_REASONS enum. */
  reason?: string;
}

interface WebKitWindow {
  webkit?: {
    messageHandlers?: {
      anglesite?: { postMessage: (body: unknown) => void };
    };
  };
}

interface AnglesiteWindow {
  anglesite?: { _handleReply?: (reply: EditReply) => void };
}

type ReplyHandler = (reply: EditReply) => void;

let editCounter = 0;
/** Monotonic-ish per-tab edit ID. Tab refresh resets the sequence; native correlates by full id. */
export function nextEditID(): string {
  editCounter += 1;
  return `e-${Date.now().toString(36)}-${editCounter}`;
}

/** Post a message to native. Returns `false` (no throw) if the WKWebView bridge isn't present —
 *  e.g. running the overlay in a plain browser tab for local debugging. */
export function postEdit(
  message: EditMessage,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.anglesite;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}

export interface PlacementPickMessage {
  id: string;
  type: "anglesite:pick-placement";
  path: string;
  selector: ElementInfo;
}

/** Posts a placement-pick report to native. No reply is awaited — the whole match/apply flow
 *  runs natively and updates the app's own placement HUD, not the page. */
export function postPlacementPick(
  message: PlacementPickMessage,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.anglesite;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}

export interface GoalElementPickMessage {
  id: string;
  type: "anglesite:pick-goal-element";
  path: string;
  selector: ElementInfo;
}

/** Posts a goal-element-pick report to native — same "no reply" contract as
 *  `postPlacementPick`; the app resolves the pick into a CSS selector and updates its own UI. */
export function postGoalElementPick(
  message: GoalElementPickMessage,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.anglesite;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}

/** Install `window.anglesite._handleReply` so native can deliver replies, and return an
 *  `awaitReply` registrar bound to a closure-private map — each install gets its own. */
export function installReplyHandler(
  win: AnglesiteWindow = window as unknown as AnglesiteWindow,
): { awaitReply: (id: string, handler: ReplyHandler) => void } {
  const pending = new Map<string, ReplyHandler>();
  win.anglesite = win.anglesite ?? {};
  win.anglesite._handleReply = (reply: EditReply) => {
    const handler = pending.get(reply.id);
    if (!handler) return;
    pending.delete(reply.id);
    handler(reply);
  };
  return {
    awaitReply: (id, handler) => {
      pending.set(id, handler);
    },
  };
}
