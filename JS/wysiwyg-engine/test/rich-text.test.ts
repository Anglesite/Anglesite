// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { runsFromElement, DebouncedCommitter } from "../src/rich-text.js";

function setBody(html: string): Element {
  document.body.innerHTML = `<div id="root">${html}</div>`;
  const root = document.getElementById("root");
  if (!root) throw new Error("missing #root");
  return root;
}

describe("runsFromElement", () => {
  it("reads plain text as a single text run", () => {
    expect(runsFromElement(setBody("Hello world"))).toEqual([{ kind: "text", text: "Hello world" }]);
  });

  it("recognizes strong, em, link, and code", () => {
    const root = setBody('Hi <strong>bold</strong> and <em>emph</em> and <a href="/x">link</a> and <code>x</code>.');
    expect(runsFromElement(root)).toEqual([
      { kind: "text", text: "Hi " },
      { kind: "strong", text: "bold" },
      { kind: "text", text: " and " },
      { kind: "em", text: "emph" },
      { kind: "text", text: " and " },
      { kind: "link", text: "link", href: "/x" },
      { kind: "text", text: " and " },
      { kind: "code", text: "x" },
      { kind: "text", text: "." },
    ]);
  });

  it("treats <b> and <i> as strong/em aliases", () => {
    const root = setBody("<b>bold</b><i>italic</i>");
    expect(runsFromElement(root)).toEqual([
      { kind: "strong", text: "bold" },
      { kind: "em", text: "italic" },
    ]);
  });

  it("flattens unrecognized markup to its text content — the honest-runs backstop", () => {
    const root = setBody('<div>block</div><span style="color:red">styled</span>');
    expect(runsFromElement(root)).toEqual([{ kind: "text", text: "blockstyled" }]);
  });

  it("merges adjacent text runs produced by flattening", () => {
    const root = setBody("start <span>middle</span> end");
    expect(runsFromElement(root)).toEqual([{ kind: "text", text: "start middle end" }]);
  });

  it("returns an empty array for an empty element", () => {
    expect(runsFromElement(setBody(""))).toEqual([]);
  });
});

describe("DebouncedCommitter", () => {
  it("commits once, after the delay, following a burst of notifyChange calls", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.notifyChange();
    vi.advanceTimersByTime(200);
    committer.notifyChange(); // resets the timer
    vi.advanceTimersByTime(200);
    expect(commits).toBe(0); // still within the debounce window from the second call

    vi.advanceTimersByTime(200);
    expect(commits).toBe(1);

    vi.useRealTimers();
  });

  it("flush() commits immediately if a commit is pending, and is a no-op otherwise", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.flush();
    expect(commits).toBe(0); // nothing pending

    committer.notifyChange();
    committer.flush();
    expect(commits).toBe(1);

    vi.advanceTimersByTime(400);
    expect(commits).toBe(1); // flush() already cancelled the pending timer

    vi.useRealTimers();
  });

  it("cancel() discards a pending commit without running it", () => {
    vi.useFakeTimers();
    let commits = 0;
    const committer = new DebouncedCommitter(() => {
      commits += 1;
    }, 400);

    committer.notifyChange();
    committer.cancel();
    vi.advanceTimersByTime(400);
    expect(commits).toBe(0);

    vi.useRealTimers();
  });
});
