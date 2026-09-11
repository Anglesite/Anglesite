// @vitest-environment jsdom
import { describe, it, expect, beforeAll, beforeEach, afterEach, vi } from "vitest";
import {
  wireImageDrop,
  IMAGE_DROP_TARGET_CLASS,
  IMAGE_DROP_ACTIVE_CLASS,
  IMAGE_DROP_HINT_ATTRIBUTE,
  type ImageReplaceReply,
  type ImageReplaceRequest,
  type ImageReplaceTransport,
} from "../../src/host/image-drop.js";
import { TOAST_CLASS } from "../../src/host/toast.js";
import "../../src/host/mount.js";

/** A transport that records requests and lets the test settle each one by hand. */
function fakeTransport(): ImageReplaceTransport & {
  requests: ImageReplaceRequest[];
  settle: (index: number, reply: ImageReplaceReply) => void;
} {
  const requests: ImageReplaceRequest[] = [];
  const resolvers: ((reply: ImageReplaceReply) => void)[] = [];
  return {
    requests,
    settle: (index, reply) => resolvers[index]?.(reply),
    requestImageReplace(request) {
      requests.push(request);
      return new Promise((resolve) => { resolvers.push(resolve); });
    },
  };
}

function makeImg(src: string, srcset?: string): HTMLImageElement {
  const img = document.createElement("img");
  img.src = src;
  if (srcset) img.setAttribute("srcset", srcset);
  document.body.appendChild(img);
  return img;
}

function imageFile(): File {
  return new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
}

/** jsdom doesn't implement DragEvent or DataTransfer, so a plain Event carries a hand-rolled
 *  `dataTransfer` — the same shim the retired overlay's suite used. */
function dragEvent(type: string, target: Element, file: File | null): Event {
  const fakeDataTransfer = {
    files: file ? [file] : [],
    items: file ? [{ kind: "file", type: file.type }] : [],
    types: file ? ["Files"] : [],
    dropEffect: "none",
  };
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", { value: fakeDataTransfer });
  target.dispatchEvent(event);
  return event;
}
function dropEffectOf(event: Event): string {
  return (event as unknown as { dataTransfer: { dropEffect: string } }).dataTransfer.dropEffect;
}

/** jsdom's FileReader completes asynchronously; poll for the request rather than counting ticks
 *  (the retired overlay's suite documents why a fixed tick count flaked under load). */
async function flushFileReader(transport: { requests: unknown[] }): Promise<void> {
  const before = transport.requests.length;
  await vi.waitFor(() => {
    if (transport.requests.length <= before) throw new Error("FileReader has not completed yet");
  });
}

/**
 * #1957 parity item 2: the retired overlay's `attachImageDrop` (`JS/edit-overlay/test/overlay.test.ts`
 * ▸ "image drop"), re-homed on the block editor. Same target highlighting, optimistic swap, and
 * reply settlement; the one deliberate difference is that a drop *away* from any `<img>` is no
 * longer accepted here — it falls through to the native drop target, which inserts a new block.
 */
describe("image drop onto an <img> (#1957)", () => {
  let transport: ReturnType<typeof fakeTransport>;
  let dispose: () => void;

  beforeAll(() => {
    if (typeof URL.createObjectURL === "undefined") {
      let blobCounter = 0;
      URL.createObjectURL = () => `blob:http://localhost/${++blobCounter}`;
      URL.revokeObjectURL = () => { /* no-op in test */ };
    }
  });

  beforeEach(() => {
    document.head.innerHTML = "";
    document.body.innerHTML = "";
    transport = fakeTransport();
    dispose = wireImageDrop(transport);
  });

  afterEach(() => {
    dispose();
  });

  it("highlights every replaceable image while a file is dragged over the page", () => {
    const first = makeImg("/images/first.jpg");
    const second = makeImg("/images/second.jpg");

    dragEvent("dragenter", document.body, imageFile());

    expect(first.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(second.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/highlighted image/i);
  });

  it("accepts the drag over an image and marks it as the active target", () => {
    const img = makeImg("/images/hero.jpg");

    const event = dragEvent("dragover", img, imageFile());

    expect(event.defaultPrevented).toBe(true);
    expect(dropEffectOf(event)).toBe("copy");
    expect(img.classList.contains(IMAGE_DROP_ACTIVE_CLASS)).toBe(true);
  });

  it("leaves a drag away from any image for the native drop target (insert as a new block)", () => {
    makeImg("/images/hero.jpg");

    const event = dragEvent("dragover", document.body, imageFile());

    expect(event.defaultPrevented).toBe(false);
    expect(dropEffectOf(event)).toBe("none");
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/anywhere else to add it/i);
  });

  it("tells the owner a page with no images will get the drop as a new image", () => {
    const event = dragEvent("dragenter", document.body, imageFile());

    expect(event.defaultPrevented).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/add this image/i);
  });

  it("ignores drags that carry no file (an in-canvas block reorder is pointer-based, not DnD)", () => {
    const img = makeImg("/images/hero.jpg");

    dragEvent("dragenter", document.body, null);
    const event = dragEvent("dragover", img, null);

    expect(event.defaultPrevented).toBe(false);
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("clears image targets when the drag leaves the page", () => {
    const img = makeImg("/images/hero.jpg");
    dragEvent("dragenter", document.body, imageFile());

    dragEvent("dragleave", document.body, imageFile());

    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("keeps targets visible until nested dragenter and dragleave events balance", () => {
    const img = makeImg("/images/hero.jpg");
    dragEvent("dragenter", document.body, imageFile());
    dragEvent("dragenter", img, imageFile());

    dragEvent("dragleave", img, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);

    dragEvent("dragleave", document.body, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("rejects a non-image file dropped on an image with guidance and prevents navigation", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File(["hello"], "notes.txt", { type: "text/plain" });

    const event = dragEvent("drop", img, file);

    expect(event.defaultPrevented).toBe(true);
    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(transport.requests).toHaveLength(0);
    expect(document.querySelector(`.${TOAST_CLASS}`)?.textContent).toMatch(/choose an image file/i);
  });

  it("still prevents navigation and clears the highlight when dataTransfer.files is empty at drop time", () => {
    const img = makeImg("/images/hero.jpg");
    dragEvent("dragenter", document.body, imageFile());

    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: { files: [], items: [], types: ["Files"], dropEffect: "none" } });
    img.dispatchEvent(drop);

    expect(drop.defaultPrevented).toBe(true);
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`.${TOAST_CLASS}`)?.textContent).toMatch(/couldn't read/i);
  });

  it("does not claim a drop away from any image", () => {
    makeImg("/images/hero.jpg");

    const event = dragEvent("drop", document.body, imageFile());

    expect(event.defaultPrevented).toBe(false);
    expect(transport.requests).toHaveLength(0);
  });

  it("sets img.src to a blob URL immediately on drop", async () => {
    const img = makeImg("/images/hero.jpg");
    dragEvent("drop", img, imageFile());
    expect(img.src.startsWith("blob:")).toBe(true);
    await flushFileReader(transport);
  });

  it("asks native to replace the image with the file's dataURL and the img's ElementInfo", async () => {
    const img = makeImg("/images/hero.jpg");
    img.id = "hero";
    dragEvent("drop", img, imageFile());
    await flushFileReader(transport);

    expect(transport.requests).toHaveLength(1);
    const request = transport.requests[0]!;
    expect(request.path).toBe(location.pathname);
    expect(request.selector.tag).toBe("IMG");
    expect(request.selector.id).toBe("hero");
    expect(request.filename).toBe("vacation.jpg");
    expect(request.mimeType).toBe("image/jpeg");
    expect(request.dataURL.startsWith("data:image/jpeg;base64,")).toBe(true);
  });

  it("captures the ElementInfo before the optimistic swap, so the sidecar sees the source-file state", async () => {
    const img = makeImg("/images/hero.jpg");
    img.className = "hero-photo";
    dragEvent("drop", img, imageFile());
    await flushFileReader(transport);

    expect(transport.requests[0]!.selector.classes).toEqual(["hero-photo"]);
  });

  it("on an applied reply, swaps to the final src/srcset and revokes the blob URL", async () => {
    const img = makeImg("/images/hero.jpg", "old-srcset");
    dragEvent("drop", img, imageFile());
    await flushFileReader(transport);
    const revokeSpy = vi.spyOn(URL, "revokeObjectURL");

    transport.settle(0, { status: "applied", result: { src: "/images/hero.webp", srcset: "new-srcset" } });
    await vi.waitFor(() => { if (!img.src.endsWith("/images/hero.webp")) throw new Error("not swapped yet"); });

    expect(img.getAttribute("srcset")).toBe("new-srcset");
    expect(revokeSpy).toHaveBeenCalled();
    expect(document.querySelector(`.${TOAST_CLASS}`)).toBeNull();
  });

  it("on a failed reply, restores the original src/srcset and shows the failure detail", async () => {
    const img = makeImg("/images/hero.jpg", "original-srcset");
    dragEvent("drop", img, imageFile());
    await flushFileReader(transport);

    transport.settle(0, { status: "failed", reason: "image-optimize-failed", detail: "sharp error" });
    await vi.waitFor(() => { if (!img.src.endsWith("/images/hero.jpg")) throw new Error("not reverted yet"); });

    expect(img.getAttribute("srcset")).toBe("original-srcset");
    expect(document.querySelector(`.${TOAST_CLASS}`)?.textContent).toContain("sharp error");
  });

  it("after 30s with no reply, restores the original and toasts a timeout", async () => {
    vi.useFakeTimers();
    try {
      const img = makeImg("/images/hero.jpg");
      dragEvent("drop", img, imageFile());
      // Just past the 30s timeout — not runAllTimers, which would also fire the toast's own
      // auto-dismiss and make the assertion miss.
      await vi.advanceTimersByTimeAsync(30_001);

      expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
      expect(document.querySelector(`.${TOAST_CLASS}`)?.textContent).toMatch(/timed out/i);
    } finally {
      vi.useRealTimers();
    }
  });

  it("dispose removes the listeners, any lingering highlight, and the stylesheet", () => {
    const img = makeImg("/images/hero.jpg");
    dragEvent("dragenter", document.body, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);

    dispose();
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.head.querySelector("style")).toBeNull();

    dragEvent("dragenter", document.body, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    dispose = () => {};
  });

  it("is wired by mount() and torn down by unmount()", () => {
    dispose();
    dispose = () => {};
    const img = makeImg("/images/hero.jpg");
    window.__anglesiteWysiwygMount!.mount({ path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} });

    dragEvent("dragenter", document.body, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);

    window.__anglesiteWysiwygMount!.unmount();
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    dragEvent("dragenter", document.body, imageFile());
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
  });
});
