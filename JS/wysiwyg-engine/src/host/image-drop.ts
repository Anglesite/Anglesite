import { elementInfoFor, type ElementInfo } from "./element-info.js";
import { showToast } from "./toast.js";

export const IMAGE_DROP_TARGET_CLASS = "anglesite-image-drop-target";
export const IMAGE_DROP_ACTIVE_CLASS = "anglesite-image-drop-active";
export const IMAGE_DROP_HINT_ATTRIBUTE = "data-anglesite-image-drop-hint";
const STYLE_ID = "__anglesite-wysiwyg-image-drop-style";
const REPLY_TIMEOUT_MS = 30_000;

/** What the page asks native to do with a file dropped onto an existing `<img>`. Mirrors the
 *  sidecar's `replace-image-src` `apply_edit` op — `selector` is the structured `ElementInfo`
 *  the sidecar resolves to a CSS selector server-side (#18), `dataURL` the file's contents. */
export interface ImageReplaceRequest {
  /** `location.pathname` at drop time — the route the sidecar patches. */
  path: string;
  selector: ElementInfo;
  filename: string;
  mimeType: string;
  dataURL: string;
}

/** Native's answer — the `EditReply` wire shape the sidecar's `apply_edit` produces, narrowed to
 *  the fields this module reacts to. `result` carries the optimized asset's final `src`/`srcset`
 *  on an applied reply. */
export interface ImageReplaceReply {
  status: "applied" | "failed" | "ambiguous";
  message?: string;
  result?: { src: string; srcset?: string };
  detail?: string;
  reason?: string;
}

/** The host seam for image replacement — `NativeHostTransport` implements it over the `wysiwyg`
 *  bridge; tests supply a fake. Never rejects: a bridge that isn't there resolves as a failed reply. */
export interface ImageReplaceTransport {
  requestImageReplace(request: ImageReplaceRequest): Promise<ImageReplaceReply>;
}

/**
 * Image drop onto an `<img>` (#1957 parity item 2 — the retired overlay's `attachImageDrop`).
 * While a file is dragged over the page every `<img>` is ringed as a drop target and the one
 * under the pointer is marked active; dropping an image file on one swaps its `src` to a blob
 * URL optimistically, asks native to replace the image (the sidecar's `replace-image-src` path —
 * optimization, metadata strip, one commit), then settles on the reply: the final `src`/`srcset`
 * on success, a revert plus a toast on failure or after `REPLY_TIMEOUT_MS`.
 *
 * Only a drag *over an `<img>`* is accepted here (`preventDefault` + `dropEffect = "copy"`). A drag
 * anywhere else is deliberately left unhandled so WKWebView declines it and the drag falls
 * through to the native side's own drop target (`SiteWindow.previewPane`'s `.onDrop`), which
 * inserts the dropped image as a *new* block at the nearest insertion point — the block editor's
 * replacement for the overlay's insert-first-image branch. The hint text tells the owner both
 * options exist.
 *
 * Returns a disposer that removes the listeners, any lingering highlight, and the stylesheet.
 */
export function wireImageDrop(transport: ImageReplaceTransport, doc: Document = document): () => void {
  installStyles(doc);
  let dragIsFile = false;
  let dragDepth = 0;
  let activeTarget: HTMLImageElement | null = null;

  const imageTargets = (): HTMLImageElement[] => Array.from(doc.querySelectorAll("img"));

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
    let hint = doc.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`) as HTMLDivElement | null;
    if (!hint) {
      hint = doc.createElement("div");
      hint.setAttribute(IMAGE_DROP_HINT_ATTRIBUTE, "");
      doc.body.appendChild(hint);
    }
    hint.textContent = targets.length > 0
      ? "Drop onto a highlighted image to replace it, or anywhere else to add it to the page"
      : "Drop anywhere to add this image to the page";
  };

  const clearTargets = (): void => {
    setActiveTarget(null);
    for (const target of imageTargets()) target.classList.remove(IMAGE_DROP_TARGET_CLASS);
    doc.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.remove();
    dragIsFile = false;
    dragDepth = 0;
  };

  const imageAtEvent = (event: DragEvent): HTMLImageElement | null => {
    const element = event.target instanceof Element ? event.target : null;
    return element?.closest("img") as HTMLImageElement | null;
  };

  const onDragEnter = (event: DragEvent) => {
    if (!isFileDrag(event.dataTransfer)) return;
    // dragenter fires once per DOM element boundary the pointer crosses, not once per page
    // entry — so only rescan/highlight on the transition into a file drag.
    const wasFileDrag = dragIsFile;
    dragIsFile = true;
    dragDepth += 1;
    if (!wasFileDrag) showTargets();
  };

  const onDragOver = (event: DragEvent) => {
    if (!dragIsFile) {
      if (!isFileDrag(event.dataTransfer)) return;
      dragIsFile = true;
      showTargets();
    }
    const target = imageAtEvent(event);
    setActiveTarget(target);
    // Accept only over an `<img>` — see the function doc comment for why a drop anywhere else is
    // left for the native drop target.
    if (!target) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
  };

  const onDragLeave = () => {
    if (!dragIsFile) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) clearTargets();
  };

  const onDrop = (event: DragEvent) => {
    const target = imageAtEvent(event);
    const file = event.dataTransfer?.files[0];
    const hadFileDrag = dragIsFile;
    clearTargets();
    if (!target) return; // not ours — native's drop target inserts a new block
    event.preventDefault();
    if (!file) {
      // dragover recognized a file drag via the always-available types/items, but `files` can
      // still come back empty at drop time for some promise-backed drag sources.
      if (hadFileDrag) showToast("Couldn't read the dropped file");
      return;
    }
    if (!file.type.startsWith("image/")) {
      showToast("Choose an image file to replace this image");
      return;
    }
    replaceImage(target, file);
  };

  const replaceImage = (target: HTMLImageElement, file: File): void => {
    const savedSrc = target.src;
    const savedSrcset = target.getAttribute("srcset");
    const selector = elementInfoFor(target);
    const blobURL = URL.createObjectURL(file);
    target.src = blobURL;
    target.removeAttribute("srcset");
    let settled = false;

    const restoreOriginal = (): void => {
      target.src = savedSrc;
      if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
      else target.removeAttribute("srcset");
      URL.revokeObjectURL(blobURL);
    };

    const revertWithToast = (text: string): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      restoreOriginal();
      showToast(text);
    };

    const timeoutHandle = setTimeout(() => revertWithToast("Image edit timed out"), REPLY_TIMEOUT_MS);

    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = reader.result;
      if (typeof dataURL !== "string") {
        revertWithToast("Couldn't read the dropped file");
        return;
      }
      void transport
        .requestImageReplace({ path: location.pathname, selector, filename: file.name, mimeType: file.type, dataURL })
        .then((reply) => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutHandle);
          if (reply.status === "applied" && reply.result) {
            target.src = reply.result.src;
            if (reply.result.srcset !== undefined) target.setAttribute("srcset", reply.result.srcset);
            else target.removeAttribute("srcset");
            URL.revokeObjectURL(blobURL);
            return;
          }
          restoreOriginal();
          showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
        });
    };
    reader.onerror = () => revertWithToast("Couldn't read the dropped file");
    reader.readAsDataURL(file);
  };

  doc.addEventListener("dragenter", onDragEnter);
  doc.addEventListener("dragover", onDragOver);
  doc.addEventListener("dragleave", onDragLeave);
  doc.addEventListener("drop", onDrop);
  // dragend fires on the drag's source node — outside this document for a real Finder drag, so
  // dragleave's depth counter is the real cleanup path; this is a defensive backstop.
  doc.addEventListener("dragend", clearTargets);

  return () => {
    doc.removeEventListener("dragenter", onDragEnter);
    doc.removeEventListener("dragover", onDragOver);
    doc.removeEventListener("dragleave", onDragLeave);
    doc.removeEventListener("drop", onDrop);
    doc.removeEventListener("dragend", clearTargets);
    clearTargets();
    doc.getElementById(STYLE_ID)?.remove();
  };
}

function installStyles(doc: Document): void {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElement("style");
  style.id = STYLE_ID;
  style.textContent = [
    // !important: site stylesheets commonly reset `img { outline: none }`, and the drop-target
    // ring needs to survive that.
    `.${IMAGE_DROP_TARGET_CLASS} { outline: 3px dashed rgba(10, 132, 255, 0.9) !important; outline-offset: 4px !important; filter: brightness(0.9) !important; }`,
    `.${IMAGE_DROP_ACTIVE_CLASS} { outline-style: solid !important; filter: brightness(1.05) !important; cursor: copy; }`,
    `[${IMAGE_DROP_HINT_ATTRIBUTE}] { position: fixed; z-index: 2147483647; left: 50%; top: 16px; transform: translateX(-50%); padding: 8px 12px; border-radius: 9px; background: rgba(28, 28, 30, 0.92); color: white; font: 600 13px/1.25 -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 4px 18px rgba(0, 0, 0, 0.25); pointer-events: none; }`,
  ].join("\n");
  doc.head.appendChild(style);
}
