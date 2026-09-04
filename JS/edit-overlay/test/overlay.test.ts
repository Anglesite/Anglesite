// @vitest-environment jsdom
import { describe, it, expect, beforeAll, beforeEach, vi } from "vitest";
import {
  install,
  HOVER_CLASS,
  EDITABLE_CLASS,
  IMAGE_DROP_TARGET_CLASS,
  IMAGE_DROP_ACTIVE_CLASS,
  IMAGE_DROP_HINT_ATTRIBUTE,
} from "../src/overlay.js";

interface WebKit {
  messageHandlers: { anglesite: { postMessage: (body: unknown) => void } };
}

let sent: unknown[] = [];

function stubWebKit(): void {
  (window as unknown as { webkit: WebKit }).webkit = {
    messageHandlers: { anglesite: { postMessage: (body) => { sent.push(body); } } },
  };
}

function clearBody(): void {
  while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
}

function makeText<K extends keyof HTMLElementTagNameMap>(parent: Element, tag: K, text: string): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  el.textContent = text;
  parent.appendChild(el);
  return el;
}

// install() registers listeners on `document` and is internally idempotent. Run it once for
// the whole file so listener attachments don't accumulate across tests; reset only per-test
// state (body DOM, post recorder) in beforeEach.
beforeAll(() => {
  // jsdom doesn't implement URL.createObjectURL / revokeObjectURL — shim them so the
  // image-drop tests can exercise the overlay behaviour without a real blob URL.
  if (typeof URL.createObjectURL === "undefined") {
    let blobCounter = 0;
    URL.createObjectURL = () => `blob:http://localhost/${++blobCounter}`;
    URL.revokeObjectURL = () => { /* no-op in test */ };
  }
  install();
});

beforeEach(() => {
  document.dispatchEvent(new Event("dragend", { bubbles: true }));
  clearBody();
  sent = [];
  stubWebKit();
});

describe("install", () => {
  it("is idempotent: a second call does not add a duplicate <style>", () => {
    install();
    install();
    const styles = document.head.querySelectorAll("style[data-anglesite-overlay]");
    expect(styles.length).toBe(1);
  });
});

describe("hover", () => {
  it("adds the hover class when mousing over a text element", () => {
    const p = makeText(document.body, "p", "Hi");
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(HOVER_CLASS)).toBe(true);
  });

  it("removes the hover class on mouseout", () => {
    const p = makeText(document.body, "p", "Hi");
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    p.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(p.classList.contains(HOVER_CLASS)).toBe(false);
  });

  it("does not add the hover class to a non-text element like <div>", () => {
    const div = document.createElement("div");
    document.body.appendChild(div);
    div.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(div.classList.contains(HOVER_CLASS)).toBe(false);
  });
});

describe("click-to-edit", () => {
  it("flips contentEditable on a text element and adds the editing class", () => {
    const p = makeText(document.body, "p", "Hello");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(p.contentEditable).toBe("true");
    expect(p.classList.contains(EDITABLE_CLASS)).toBe(true);
  });

  it("posts an EditMessage on blur when the text changed", () => {
    const main = document.createElement("main");
    document.body.appendChild(main);
    const p = makeText(main, "p", "old");

    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { type: string; op: string; selector: { tag: string; ancestors?: Array<{ tag: string }> }; value: unknown };
    expect(msg.type).toBe("anglesite:apply-edit");
    expect(msg.op).toBe("replace-text");
    expect(msg.value).toBe("new");
    expect(msg.selector.tag).toBe("P");
    expect(msg.selector.ancestors?.map((a) => a.tag)).toEqual(["BODY", "MAIN"]);
  });

  it("does not post on blur when the text is unchanged", () => {
    const p = makeText(document.body, "p", "same");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.dispatchEvent(new FocusEvent("blur"));
    expect(sent.length).toBe(0);
  });

  it("captures selector.textContent from the ORIGINAL text, not the edited one", () => {
    // Regression: an earlier version called `elementInfoFor(target)` inside the blur handler,
    // after the user had typed — sending the new text as `selector.textContent`. The
    // server-side patcher then couldn't find the element in the source file (which still
    // contained the original text), and no edit was applied.
    const p = makeText(document.body, "p", "original-text");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new-text-the-user-typed";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { selector: { textContent?: string }; value: unknown };
    expect(msg.selector.textContent).toBe("original-text");
    expect(msg.value).toBe("new-text-the-user-typed");
  });

  it("captures a Writing Tools rewrite as a single replace-text edit (#91)", () => {
    // Apple Intelligence Writing Tools applies its rewrite inline to the DOM while the element is
    // still focused/contentEditable — modeled here by mutating `textContent` after the click but
    // before blur. The blur-time diff must then send exactly one `replace-text` apply-edit carrying
    // the rewritten text, so the rewrite lands as one undoable commit through the existing pipeline.
    const main = document.createElement("main");
    document.body.appendChild(main);
    const p = makeText(main, "p", "we makes great stuff");

    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    // WebKit's Writing Tools rewrite of the contentEditable element.
    p.textContent = "We make great things.";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(sent.length).toBe(1);
    const msg = sent[0] as { type: string; op: string; selector: { textContent?: string }; value: unknown };
    expect(msg.type).toBe("anglesite:apply-edit");
    expect(msg.op).toBe("replace-text");
    expect(msg.value).toBe("We make great things.");
    // Selector snapshot reflects the pre-rewrite source text so the server-side patcher resolves it.
    expect(msg.selector.textContent).toBe("we makes great stuff");
  });

  // #1851: the overlay used to apply the DOM edit optimistically and then ignore the reply
  // entirely — a refused persist (e.g. the container's guest clone had fallen behind Source/'s
  // HEAD) left the page showing text that was never actually saved, with no toast and nothing to
  // undo. These pin the fix: a non-"applied" reply must revert the DOM and surface a toast.
  it("on edit-applied, keeps the edited text and shows no toast", () => {
    const p = makeText(document.body, "p", "old");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new";
    p.dispatchEvent(new FocusEvent("blur"));
    const id = (sent[0] as { id: string }).id;

    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "applied",
    });

    expect(p.textContent).toBe("new");
    expect(document.querySelector(".anglesite-toast")).toBeNull();
  });

  it("on edit-failed, reverts to the original text and shows a toast with the failure detail", () => {
    const p = makeText(document.body, "p", "old");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new";
    p.dispatchEvent(new FocusEvent("blur"));
    const id = (sent[0] as { id: string }).id;

    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "failed", message: "The edit changed the preview but couldn't be saved to Source: conflict",
    });

    expect(p.textContent).toBe("old");
    expect(document.querySelector(".anglesite-toast")?.textContent).toContain("couldn't be saved to Source");
  });

  it("reverts immediately with a toast when the WKWebView bridge isn't present", () => {
    (window as unknown as { webkit?: unknown }).webkit = undefined;
    const p = makeText(document.body, "p", "old");
    p.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    p.textContent = "new";
    p.dispatchEvent(new FocusEvent("blur"));

    expect(p.textContent).toBe("old");
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/not running inside the anglesite app/i);
  });
});

describe("image drop", () => {
  function makeImg(src: string, srcset?: string): HTMLImageElement {
    const img = document.createElement("img");
    img.src = src;
    if (srcset) img.setAttribute("srcset", srcset);
    document.body.appendChild(img);
    return img;
  }

  /** jsdom 25 doesn't implement DragEvent or DataTransfer, so we use a plain Event
   *  and define dataTransfer directly on the instance. */
  function dropOn(target: Element, file: File): Event {
    const fakeDataTransfer = {
      files: [file],
      items: [{ kind: "file", type: file.type }],
      types: ["Files"],
      dropEffect: "none",
    };
    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: fakeDataTransfer });
    target.dispatchEvent(drop);
    return drop;
  }

  function dragOn(type: "dragenter" | "dragover" | "dragleave", target: Element, file: File): Event {
    const fakeDataTransfer = {
      files: [file],
      items: [{ kind: "file", type: file.type }],
      types: ["Files"],
      dropEffect: "none",
    };
    const event = new Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, "dataTransfer", { value: fakeDataTransfer });
    target.dispatchEvent(event);
    return event;
  }

  /** jsdom's FileReader resolves its read via two chained `setImmediate` calls internally
   *  (see node_modules/jsdom/lib/jsdom/living/file-api/FileReader-impl.js). A fixed count of
   *  `setTimeout(fn, 0)` ticks is NOT a reliable way to wait for that: Node only guarantees
   *  `setImmediate` runs before a same-tick `setTimeout(fn, 0)` when both are scheduled from
   *  inside an I/O callback — here they're scheduled from the test body instead, so their
   *  relative order across the timers vs. check phases is unspecified and can flip under load
   *  (confirmed empirically: ~0.1% of trials one way in a tight loop, more when the event loop
   *  is busier, e.g. CI). That let the "flush" resolve before the reader's onload ran (dropping
   *  `sent` to 0) or let a *previous* test's still-pending onload fire during the *next* test
   *  (bumping `sent` to 2) — matching both observed CI failure shapes. Poll for the actual
   *  effect (a new `sent` entry) instead of guessing tick counts.
   */
  async function flushFileReader(): Promise<void> {
    const before = sent.length;
    await vi.waitFor(() => {
      if (sent.length <= before) throw new Error("FileReader has not completed yet");
    });
  }

  it("highlights every replaceable image while a Finder file is dragged over the page", () => {
    const first = makeImg("/images/first.jpg");
    const second = makeImg("/images/second.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragenter", document.body, file);

    expect(event.defaultPrevented).toBe(true);
    expect(first.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(second.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/highlighted image/i);
  });

  it("shows which image will receive the drop", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragover", img, file);

    expect(event.defaultPrevented).toBe(true);
    expect(img.classList.contains(IMAGE_DROP_ACTIVE_CLASS)).toBe(true);
  });

  it("accepts the drop anywhere on a page with no images, not just directly over an image", () => {
    // Regression guard: dropEffect must become "copy" here, or the OS rejects the drop (macOS's
    // "poof back to origin" animation) before the `drop` handler's insert-new-image branch ever
    // runs — the exact bug this test would have caught.
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragover", document.body, file);

    expect((event as unknown as { dataTransfer: { dropEffect: string } }).dataTransfer.dropEffect).toBe("copy");
  });

  it("keeps rejecting drops away from any image when the page already has one (replace-only stays gated)", () => {
    makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragover", document.body, file);

    expect((event as unknown as { dataTransfer: { dropEffect: string } }).dataTransfer.dropEffect).toBe("none");
  });

  it("clears image targets when the drag leaves the page", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dragOn("dragenter", document.body, file);

    dragOn("dragleave", document.body, file);

    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("keeps targets visible until nested dragenter and dragleave events balance", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dragOn("dragenter", document.body, file);
    dragOn("dragenter", img, file);

    dragOn("dragleave", img, file);
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).not.toBeNull();

    dragOn("dragleave", document.body, file);
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
  });

  it("explains an image drop outside a replaceable image instead of failing silently", () => {
    makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    dropOn(document.body, file);

    expect(sent.length).toBe(0);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/highlighted image/i);
  });

  it("explains a non-image file dropped outside a replaceable image without implying one was targeted", () => {
    makeImg("/images/hero.jpg");
    const file = new File(["notes"], "notes.txt", { type: "text/plain" });

    dropOn(document.body, file);

    expect(sent.length).toBe(0);
    const toastText = document.querySelector(".anglesite-toast")?.textContent ?? "";
    expect(toastText).toMatch(/image file/i);
    expect(toastText).toMatch(/highlighted image/i);
    expect(toastText).not.toMatch(/replace this image/i);
  });

  it("rejects a non-image file with guidance and prevents WKWebView navigation", () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File(["notes"], "notes.txt", { type: "text/plain" });

    const event = dropOn(img, file);

    expect(event.defaultPrevented).toBe(true);
    expect(sent.length).toBe(0);
    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/choose an image file/i);
  });

  it("still prevents WKWebView navigation and clears the highlight when dataTransfer.files is empty at drop time", () => {
    // A recognized file drag (dragenter/dragover already saw "Files" in dataTransfer.types) can
    // still arrive at drop with an empty .files — e.g. a promise-backed/multi-item drag source.
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dragOn("dragenter", document.body, file);

    const fakeDataTransfer = { files: [], items: [{ kind: "file", type: "image/jpeg" }], types: ["Files"], dropEffect: "none" };
    const drop = new Event("drop", { bubbles: true, cancelable: true });
    Object.defineProperty(drop, "dataTransfer", { value: fakeDataTransfer });
    document.body.dispatchEvent(drop);

    expect(drop.defaultPrevented).toBe(true);
    expect(sent.length).toBe(0);
    expect(img.classList.contains(IMAGE_DROP_TARGET_CLASS)).toBe(false);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)).toBeNull();
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/couldn't read/i);
  });

  it("sets img.src to a blob URL immediately on drop", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    expect(img.src.startsWith("blob:")).toBe(true);
    // Drain the pending FileReader so it doesn't bleed into the next test.
    await flushFileReader();
  });

  it("posts apply-edit with op: replace-image-src and dataURL value", async () => {
    const img = makeImg("/images/hero.jpg");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    expect(sent.length).toBe(1);
    const msg = sent[0] as { op: string; value: { filename: string; mimeType: string; dataURL: string } };
    expect(msg.op).toBe("replace-image-src");
    expect(msg.value.filename).toBe("vacation.jpg");
    expect(msg.value.mimeType).toBe("image/jpeg");
    expect(msg.value.dataURL.startsWith("data:image/jpeg;base64,")).toBe(true);
  });

  it("on edit-applied with result, swaps src/srcset and revokes the blob URL", async () => {
    const img = makeImg("/images/hero.jpg", "old-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    const revokeSpy = vi.spyOn(URL, "revokeObjectURL");
    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "applied", result: { src: "/images/hero.webp", srcset: "new-srcset" },
    });

    expect(img.src.endsWith("/images/hero.webp")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("new-srcset");
    expect(revokeSpy).toHaveBeenCalled();
  });

  it("on edit-failed, restores original src/srcset, revokes blob URL, and shows a toast", async () => {
    const img = makeImg("/images/hero.jpg", "original-srcset");
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
    dropOn(img, file);
    await flushFileReader();
    const id = (sent[0] as { id: string }).id;

    (window as unknown as { anglesite: { _handleReply: (r: unknown) => void } }).anglesite._handleReply({
      id, status: "failed", reason: "image-optimize-failed", detail: "sharp error",
    });

    expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
    expect(img.getAttribute("srcset")).toBe("original-srcset");
    expect(document.querySelector(".anglesite-toast")?.textContent).toContain("sharp error");
  });

  it("after 30s with no reply, restores original and toasts a timeout", async () => {
    vi.useFakeTimers();
    try {
      const img = makeImg("/images/hero.jpg");
      const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });
      dropOn(img, file);
      // Advance just past the 30s timeout (not runAllTimers, which would also
      // fire the toast's 4s auto-dismiss and make the assertion miss).
      await vi.advanceTimersByTimeAsync(30001);

      expect(img.src.endsWith("/images/hero.jpg")).toBe(true);
      expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/timed out/i);
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows an insert hint instead of a replace hint when the page has no images", () => {
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    const event = dragOn("dragenter", document.body, file);

    expect(event.defaultPrevented).toBe(true);
    expect(document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.textContent).toMatch(/add this page's first image/i);
  });

  it("inserts a new image when dropped anywhere on a page with no images", async () => {
    const file = new File([new Uint8Array([0xff, 0xd8])], "vacation.jpg", { type: "image/jpeg" });

    dropOn(document.body, file);
    await flushFileReader();

    expect(sent.length).toBe(1);
    const msg = sent[0] as { op: string; selector?: unknown; value: { filename: string } };
    expect(msg.op).toBe("insert-image");
    expect(msg.selector).toBeUndefined();
    expect(msg.value.filename).toBe("vacation.jpg");
    // Optimistic insert: a new <img> is in the DOM immediately, pointing at a blob URL.
    const inserted = document.querySelector("img");
    expect(inserted).not.toBeNull();
    expect(inserted?.src).toMatch(/^blob:/);
  });

  it("explains a non-image file dropped on a page with no images without implying insert", () => {
    const file = new File(["notes"], "notes.txt", { type: "text/plain" });

    dropOn(document.body, file);

    expect(sent.length).toBe(0);
    expect(document.querySelector(".anglesite-toast")?.textContent).toMatch(/image file/i);
    expect(document.querySelector("img")).toBeNull();
  });
});
