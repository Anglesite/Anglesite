# WYSIWYG Mac Host Chrome — PR3 (Polish/Accessibility) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the WYSIWYG canvas (#1225) a real keyboard-only editing grammar (arrows move block
selection, Return enters text editing, Escape exits the deepest active context first) and VoiceOver
block navigation by owner-facing names, then run the §8.5 WKWebView text-services acceptance check
(spelling, dictation, IME, autocorrect, Services, Look Up, grammar) — issue #1589, PR3 of 3 for
slice 4.

**Scope note (descoped from the issue body):** #1589's body also lists "document conventions"
(proxy icon, edited-dot, ⌘F find bar) as PR3 scope, mirroring the reopening comment on #1225. But
open PR #1613 (part of #1588/PR2, native panels) already ships all three of those — its own PR body
says "PR3 (polish/keyboard/VoiceOver/text-services) follows separately, so this PR intentionally
does not close #1588." Re-implementing them here would duplicate in-flight work and guarantee a
merge conflict, so this plan covers only keyboard grammar, VoiceOver, and the text-services check.
Confirmed with the repo owner before writing this plan.

**Tab-walks-props is out of scope for this plan.** The keyboard grammar's "Tab walks props" needs a
per-block prop UI to walk into, and that's PR2's native inspector — still unmerged in #1613. Task 9
below files a follow-up issue for it once #1613 lands, rather than building a throwaway interim UI
here (confirmed with the repo owner). Arrows/Return/Escape do not depend on the inspector and ship
in this plan.

**Architecture:** A new JS `KeyboardNavigation` class (`JS/wysiwyg-engine/src/keyboard-nav.ts`)
attaches a `document`-level `keydown` listener — mirroring `mount.ts`'s existing document-level
`contextmenu` listener — and drives the engine's existing `selection: SelectionState` and
`RichTextEditor`. A new `AccessibilityAnnotator` (`JS/wysiwyg-engine/src/accessibility.ts`) keeps
`role`/`aria-label`/`aria-selected`/`tabindex` on each block's already-rendered DOM element (found
via `findBlockElement`, the same lookup `RichTextEditor.enter()` uses) in sync with the model and
selection, and calls `.focus()` on the selected element so VoiceOver announces it — "the block
model doubles as the accessibility model" (design doc §8.6). Selection changes reach the Swift side
through a new `selection-changed` message on the existing `wysiwyg` script-message namespace
(`WYSIWYGOpsDispatcher`), the same pattern `context-menu` already uses, so
`WYSIWYGCanvasController.selectedBlockId` stays the single source of truth Duplicate/Delete already
read. The text-services check (Task 8) is manual QA against the real running app — no code is
written for it unless the check finds WKWebView's built-in text services insufficient, in which
case the NSTextView-overlay contingency becomes its own follow-up plan (not pre-built, per the
design doc).

**Tech Stack:** Swift 6.4 (`AnglesiteBridgeCore`, `AnglesiteBridge`, `AnglesiteApp` targets), Swift
Testing, TypeScript (`JS/wysiwyg-engine/`), vitest (`@vitest-environment jsdom`), esbuild.

**Spec:** `docs/superpowers/specs/2026-08-10-wysiwyg-mac-host-chrome-design.md` (§5, PR3), and the
release-acceptance checklist in `docs/mac-assed-app-spec.md` (§"Can a keyboard-only user and a
VoiceOver user complete the core flows?" / "text services... spelling and grammar... input
methods, dictation, and accessibility").

## Global Constraints

- Swift/SwiftUI + Apple frameworks only — no third-party dependencies (CONTRIBUTING.md).
- No silent failure paths — bridge decode failures already log via `LogCenter`; new code follows
  the same convention (CLAUDE.md "logs are sacred").
- Conventional commits, subject ≤72 chars, reference `#1589` (CONTRIBUTING.md). Do **not** use
  `fix(#1589): ...`/`feat(#1589): ...` as a commit *type+scope* on every intermediate commit if this
  PR might ship interim review-fix commits before its own close — this issue isn't a multi-PR
  tracking issue the way #1225 was, so normal `feat(#1589): ...`/`fix(#1589): ...` commits are fine
  here; this note exists only because CONTRIBUTING.md flags the collision pattern explicitly.
- Follow existing patterns exactly where one already exists for the same shape: the
  `context-menu` message (`WYSIWYGOpsDispatcher`/`WYSIWYGScriptHandler`/`PreviewView.makeWYSIWYGHandler`)
  is the precedent for `selection-changed`; `mount.ts`'s document-level `contextmenu` listener is
  the precedent for `KeyboardNavigation`'s `keydown` listener.
- `StubWYSIWYGHostTransport`/`SidecarWYSIWYGHostTransport` are unaffected — this plan touches
  selection and keyboard/accessibility state only, never the ops/transport layer.

---

### Task 1: `selection-changed` bridge message (dispatcher)

**Files:**
- Modify: `Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift`

**Interfaces:**
- Produces: `WYSIWYGOpsDispatcher.DispatchResult.selectionChanged(blockId: BlockId?)`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift`, inside the
`WYSIWYGOpsDispatcherTests` struct (it already declares a `RecordingTransport` actor conforming to
`WYSIWYGHostTransport` — reuse it exactly as the existing `routesSubmitOp` test does):

```swift
@Test("dispatch routes selection-changed to .selectionChanged with the reported block")
func dispatchRoutesSelectionChanged() async {
    let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
    let transport = RecordingTransport(reply: .applied(model: model))
    let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": "b1"], via: transport)
    guard case .selectionChanged(let blockId) = result else {
        Issue.record("expected .selectionChanged, got \(result)")
        return
    }
    #expect(blockId == "b1")
}

@Test("dispatch routes selection-changed with a null blockId to .selectionChanged(nil)")
func dispatchRoutesSelectionChangedClear() async {
    let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
    let transport = RecordingTransport(reply: .applied(model: model))
    let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": NSNull()], via: transport)
    guard case .selectionChanged(let blockId) = result else {
        Issue.record("expected .selectionChanged, got \(result)")
        return
    }
    #expect(blockId == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: FAIL — `.selectionChanged` doesn't exist yet (build error).

- [ ] **Step 3: Add the case and dispatch branch**

In `WYSIWYGOpsDispatcher.swift`, add to `DispatchResult`:

```swift
/// `selection-changed` reported the block the owner (keyboard nav, click-to-select) currently has
/// selected, or `nil` when selection was cleared. The adapter should update its `selectedBlockId`
/// so Duplicate/Delete keep acting on the right block. No reply is sent back to the page — mirrors
/// `.contextMenu`.
case selectionChanged(blockId: BlockId?)
```

Add a case to the `switch typeStr` in `dispatch(body:via:)`, alongside `"context-menu"`:

```swift
case "selection-changed":
    return .selectionChanged(blockId: dict["blockId"] as? String)
```

(`as? String` naturally yields `nil` for both a missing key and a JS `null`, which is the correct
"no selection" outcome for both.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift
git commit -m "feat(#1589): add selection-changed to the wysiwyg bridge dispatcher"
```

---

### Task 2: Wire `selection-changed` into `WYSIWYGScriptHandler` and `PreviewView`

**Files:**
- Modify: `Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`
- Modify: `Sources/AnglesiteApp/PreviewView.swift:126-139` (`makeWYSIWYGHandler`)

**Interfaces:**
- Consumes: `WYSIWYGOpsDispatcher.DispatchResult.selectionChanged(blockId:)` (Task 1)
- Produces: `WYSIWYGScriptHandler.init(transport:logCenter:onContextMenu:onSelectionChanged:)`,
  `WYSIWYGCanvasController.selectedBlockId` now updated from keyboard/JS-driven selection too.

- [ ] **Step 1: Add `onSelectionChanged` to `WYSIWYGScriptHandler`**

In `Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`, add a stored closure alongside
`onContextMenu`:

```swift
private let onSelectionChanged: (@Sendable (BlockId?) -> Void)?
```

Add it as an `init` parameter (default `nil`, same as `onContextMenu`):

```swift
public init(
    transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared,
    onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
    onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil
) {
    self.transport = transport
    self.logCenter = logCenter
    self.onContextMenu = onContextMenu
    self.onSelectionChanged = onSelectionChanged
    super.init()
}
```

Capture it in `userContentController(_:didReceive:)` (alongside the existing `onContextMenu`
capture) and add a case to the `switch`:

```swift
case .selectionChanged(let blockId):
    onSelectionChanged?(blockId)
```

- [ ] **Step 2: Wire it in `PreviewView.makeWYSIWYGHandler`**

In `Sources/AnglesiteApp/PreviewView.swift`, change the call from trailing-closure sugar (which
would now bind to the wrong parameter) to explicit labeled arguments:

```swift
private func makeWYSIWYGHandler(for controller: WYSIWYGCanvasController, coordinator: Coordinator) -> WYSIWYGScriptHandler {
    WYSIWYGScriptHandler(
        transport: controller,
        onContextMenu: { [weak coordinator] blockId, point in
            Task { @MainActor in
                guard let webView = coordinator?.webView else { return }
                let menu = WYSIWYGBlockContextMenu.build(for: blockId, controller: controller)
                let converted = Self.convertContextMenuPoint(point, viewHeight: webView.bounds.height)
                menu.popUp(positioning: nil, at: converted, in: webView)
            }
        },
        onSelectionChanged: { [weak controller] blockId in
            Task { @MainActor in
                controller?.selectedBlockId = blockId
            }
        }
    )
}
```

(`controller` is already a parameter of `makeWYSIWYGHandler`, captured weakly the same way
`coordinator` is in the existing closure — no new stored property needed.)

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED (this task has no new automated test — it's plumbing between two already-tested
layers; Task 8's manual pass exercises it end-to-end).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift Sources/AnglesiteApp/PreviewView.swift
git commit -m "feat(#1589): sync selectedBlockId from JS-driven selection changes"
```

---

### Task 3: `RichTextEditor` stops propagation on its own Escape

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts:220-222`
- Test: `JS/wysiwyg-engine/test/rich-text.test.ts` (add to the existing file — find its exact
  existing `describe`/import style before adding, match it exactly)

**Interfaces:**
- Produces: `RichTextEditor`'s Escape handling now stops the event from reaching a document-level
  listener (Task 4's `KeyboardNavigation`) on the same keypress that exited editing.

This is the fix that makes "Escape exits the deepest context first" actually work: without it, one
Escape press while text-editing would both exit editing *and* clear block selection in the same
event, skipping the intermediate "text-editing → block-selected" step design doc §8.6 requires.

- [ ] **Step 1: Write the failing test**

```typescript
it("exiting via Escape stops the event from reaching a document-level listener", () => {
  const engine = new WysiwygEngine(
    { path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: { b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] } } },
    { sendOp: async () => ({ status: "applied", model: { path: "src/pages/index.astro", version: "v1", rootIds: ["b1"], blocks: {} } }), onModelUpdate: () => () => {} },
  );
  document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
  const editor = new RichTextEditor(engine);
  editor.enter("b1");

  const documentListener = vi.fn();
  document.addEventListener("keydown", documentListener);

  const el = document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement;
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

  expect(editor.activeBlockId).toBeNull();
  expect(documentListener).not.toHaveBeenCalled();
  document.removeEventListener("keydown", documentListener);
});
```

(Add the `// @vitest-environment jsdom` header comment at the top of the file if it isn't already
there, matching `test/host/mount.test.ts`'s convention.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- rich-text.test.ts` (from `JS/wysiwyg-engine/`)
Expected: FAIL — `documentListener` was called (event still bubbled).

- [ ] **Step 3: Add `stopPropagation()`**

In `JS/wysiwyg-engine/src/rich-text.ts`, change:

```typescript
#onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") this.exit();
};
```

to:

```typescript
#onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      this.exit();
      event.stopPropagation();
    }
};
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- rich-text.test.ts`
Expected: PASS

- [ ] **Step 5: Run the full JS suite to check nothing else broke**

Run: `npm test` (from `JS/wysiwyg-engine/`)
Expected: PASS (this method is only reachable via a real Escape keypress on the active element; no
other test should depend on it continuing to bubble)

- [ ] **Step 6: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "fix(#1589): stop Escape from reaching document nav after exiting text editing"
```

---

### Task 4: `KeyboardNavigation` — arrows/Return/Escape grammar

**Files:**
- Create: `JS/wysiwyg-engine/src/keyboard-nav.ts`
- Test: `JS/wysiwyg-engine/test/keyboard-nav.test.ts`

**Interfaces:**
- Consumes: `WysiwygEngine.selection` (`SelectionState`, `select`/`clear`/`current`),
  `WysiwygEngine.modelSync.current` (`BlockModel`), `RichTextEditor.activeBlockId`,
  `RichTextEditor.enter(blockId, root?)` (all pre-existing, from `engine.ts`/`selection.ts`/`rich-text.ts`)
- Produces: `class KeyboardNavigation { constructor(engine: WysiwygEngine, richText: RichTextEditor, target?: GlobalEventHandlers); dispose(): void }`

- [ ] **Step 1: Write the failing tests**

```typescript
// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { WysiwygEngine } from "../src/engine.js";
import { RichTextEditor } from "../src/rich-text.js";
import { KeyboardNavigation } from "../src/keyboard-nav.js";
import type { BlockModel, HostTransport } from "../src/types.js";

function fixtureModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v0",
    rootIds: ["b1", "b2", "b3"],
    blocks: {
      b1: { id: "b1", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [{ kind: "text", text: "one" }] },
      b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: {}, slots: {}, sourceSpan: [0, 0] },
      b3: { id: "b3", kind: "text", componentName: "p", props: {}, slots: {}, sourceSpan: [0, 0], richText: [{ kind: "text", text: "three" }] },
    },
  };
}

function fixtureTransport(): HostTransport {
  return { sendOp: async () => ({ status: "applied", model: fixtureModel() }), onModelUpdate: () => () => {} };
}

function dispatchKey(target: EventTarget, key: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

describe("KeyboardNavigation (#1589)", () => {
  it("ArrowDown selects the first block when nothing is selected", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBe("b1");
  });

  it("ArrowDown/ArrowUp move selection forward/backward through rootIds, clamped at the ends", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);

    dispatchKey(document, "ArrowDown");
    dispatchKey(document, "ArrowDown");
    expect(engine.selection.current).toBe("b2");

    dispatchKey(document, "ArrowDown");
    dispatchKey(document, "ArrowDown"); // already at the last block — stays clamped
    expect(engine.selection.current).toBe("b3");

    dispatchKey(document, "ArrowUp");
    expect(engine.selection.current).toBe("b2");
  });

  it("Return enters text editing on a selected text-kind block", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");

    dispatchKey(document, "Enter");

    expect(richText.activeBlockId).toBe("b1");
  });

  it("Return no-ops on a non-text-kind selected block", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b2");

    dispatchKey(document, "Enter");

    expect(richText.activeBlockId).toBeNull();
  });

  it("Escape clears block selection when not editing", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");

    dispatchKey(document, "Escape");

    expect(engine.selection.current).toBeNull();
  });

  it("arrows/Return/Escape are no-ops while a text-editing session is active", () => {
    document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    new KeyboardNavigation(engine, richText, document);
    engine.selection.select("b1");
    richText.enter("b1");

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBe("b1"); // unchanged — the caret moves, not block selection
  });

  it("dispose() removes the keydown listener", () => {
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    const richText = new RichTextEditor(engine);
    const nav = new KeyboardNavigation(engine, richText, document);
    nav.dispose();

    dispatchKey(document, "ArrowDown");

    expect(engine.selection.current).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- keyboard-nav.test.ts` (from `JS/wysiwyg-engine/`)
Expected: FAIL — `src/keyboard-nav.js` doesn't exist yet.

- [ ] **Step 3: Write `KeyboardNavigation`**

```typescript
// JS/wysiwyg-engine/src/keyboard-nav.ts
import type { BlockId } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import type { RichTextEditor } from "./rich-text.js";

/**
 * Keyboard-only editing grammar (design doc §8.6): arrows move block selection, Return enters text
 * editing on the selected block, Escape exits the deepest active context first — text-editing (via
 * `RichTextEditor`'s own Escape handling, which stops propagation once it fires — see rich-text.ts),
 * then block-selected, then none.
 *
 * Tab-walks-props is deliberately not handled here: it needs the native inspector PR2 ships
 * (#1588/#1613), which doesn't exist on `main` yet — see this plan's header and #1589's PR body.
 *
 * Listens on `document` (default `target`) rather than a specific block element, mirroring
 * `mount.ts`'s own `contextmenu` listener: whichever element already has focus (a block, or
 * nothing) is where these keys should apply, and re-deriving that per-block would just reduce to
 * `document.activeElement` anyway. `target` is overridable for tests and for a future breakpoint
 * frame's own `Document` (matching `hitTest`/`findBlockElement`'s existing `root` parameter
 * convention elsewhere in this package).
 */
export class KeyboardNavigation {
  #engine: WysiwygEngine;
  #richText: RichTextEditor;
  #target: GlobalEventHandlers;
  #onKeydown = (event: Event) => this.#handleKeydown(event as KeyboardEvent);

  constructor(engine: WysiwygEngine, richText: RichTextEditor, target: GlobalEventHandlers = document) {
    this.#engine = engine;
    this.#richText = richText;
    this.#target = target;
    target.addEventListener("keydown", this.#onKeydown);
  }

  dispose(): void {
    this.#target.removeEventListener("keydown", this.#onKeydown);
  }

  #handleKeydown(event: KeyboardEvent): void {
    // A live text-editing session owns arrows/Return/Escape for caret movement and text input.
    if (this.#richText.activeBlockId !== null) return;

    switch (event.key) {
      case "ArrowDown":
      case "ArrowRight":
        this.#moveSelection(1);
        event.preventDefault();
        break;
      case "ArrowUp":
      case "ArrowLeft":
        this.#moveSelection(-1);
        event.preventDefault();
        break;
      case "Enter":
      case "Return":
        if (this.#enterTextEditingIfPossible()) event.preventDefault();
        break;
      case "Escape":
        if (this.#engine.selection.current !== null) {
          this.#engine.selection.clear();
          event.preventDefault();
        }
        break;
    }
  }

  #moveSelection(delta: 1 | -1): void {
    const { rootIds } = this.#engine.modelSync.current;
    if (rootIds.length === 0) return;
    const current = this.#engine.selection.current;
    const currentIndex = current === null ? -1 : rootIds.indexOf(current);
    const nextIndex =
      currentIndex === -1
        ? (delta === 1 ? 0 : rootIds.length - 1)
        : Math.min(Math.max(currentIndex + delta, 0), rootIds.length - 1);
    this.#engine.selection.select(rootIds[nextIndex] as BlockId);
  }

  #enterTextEditingIfPossible(): boolean {
    const selected = this.#engine.selection.current;
    if (selected === null) return false;
    const node = this.#engine.modelSync.current.blocks[selected];
    if (!node || node.kind !== "text") return false;
    this.#richText.enter(selected);
    return true;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- keyboard-nav.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/keyboard-nav.ts JS/wysiwyg-engine/test/keyboard-nav.test.ts
git commit -m "feat(#1589): add keyboard-only block-selection and text-editing grammar"
```

---

### Task 5: `AccessibilityAnnotator` — VoiceOver labels + roving focus

**Files:**
- Create: `JS/wysiwyg-engine/src/accessibility.ts`
- Test: `JS/wysiwyg-engine/test/accessibility.test.ts`

**Interfaces:**
- Consumes: `WysiwygEngine.onEvent`, `WysiwygEngine.selection.onChange`, `WysiwygEngine.modelSync.current`,
  `findBlockElement` (from `selection.ts`)
- Produces: `class AccessibilityAnnotator { constructor(engine: WysiwygEngine, displayNames: Record<string, string>, root?: ParentNode); displayName(componentName: string): string; dispose(): void }`

- [ ] **Step 1: Write the failing tests**

```typescript
// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { WysiwygEngine } from "../src/engine.js";
import { AccessibilityAnnotator } from "../src/accessibility.js";
import type { BlockModel, HostTransport } from "../src/types.js";

function fixtureModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v0",
    rootIds: ["b1", "b2"],
    blocks: {
      b1: { id: "b1", kind: "text", componentName: "h2", props: {}, slots: {}, sourceSpan: [0, 0], richText: [] },
      b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: {}, slots: {}, sourceSpan: [0, 0] },
    },
  };
}

function fixtureTransport(): HostTransport {
  return { sendOp: async () => ({ status: "applied", model: fixtureModel() }), onModelUpdate: () => () => {} };
}

describe("AccessibilityAnnotator (#1589)", () => {
  it("labels each block with its palette display name, falling back to componentName", () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2><div data-anglesite-block-id="b2"></div>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    new AccessibilityAnnotator(engine, { h2: "Heading" });

    const b1 = document.querySelector('[data-anglesite-block-id="b1"]')!;
    const b2 = document.querySelector('[data-anglesite-block-id="b2"]')!;
    expect(b1.getAttribute("aria-label")).toBe("Heading");
    expect(b1.getAttribute("role")).toBe("group");
    expect(b2.getAttribute("aria-label")).toBe("Testimonial"); // no palette entry — falls back to componentName
  });

  it("sets aria-selected and roving tabindex, and moves focus, when selection changes", () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2><div data-anglesite-block-id="b2"></div>`;
    const engine = new WysiwygEngine(fixtureModel(), fixtureTransport());
    new AccessibilityAnnotator(engine, {});

    engine.selection.select("b1");

    const b1 = document.querySelector('[data-anglesite-block-id="b1"]') as HTMLElement;
    const b2 = document.querySelector('[data-anglesite-block-id="b2"]') as HTMLElement;
    expect(b1.getAttribute("aria-selected")).toBe("true");
    expect(b1.tabIndex).toBe(0);
    expect(b2.getAttribute("aria-selected")).toBe("false");
    expect(b2.tabIndex).toBe(-1);
    expect(document.activeElement).toBe(b1);
  });

  it("re-annotates after a model update (e.g. a new block inserted)", async () => {
    document.body.innerHTML = `<h2 data-anglesite-block-id="b1"></h2>`;
    const engine = new WysiwygEngine({ ...fixtureModel(), rootIds: ["b1"], blocks: { b1: fixtureModel().blocks.b1 } }, fixtureTransport());
    new AccessibilityAnnotator(engine, { h2: "Heading" });

    document.body.innerHTML += `<div data-anglesite-block-id="b2"></div>`;
    await engine.submit({ kind: "setDesignToken", tokenName: "x", value: "1", previousValue: "0" });

    const b2 = document.querySelector('[data-anglesite-block-id="b2"]')!;
    // fixtureTransport's sendOp always resolves with fixtureModel(), which includes b2 — proves
    // the annotator re-ran after the applied event, not just once at construction.
    expect(b2.getAttribute("aria-label")).toBe("Testimonial");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- accessibility.test.ts` (from `JS/wysiwyg-engine/`)
Expected: FAIL — `src/accessibility.js` doesn't exist yet.

- [ ] **Step 3: Write `AccessibilityAnnotator`**

```typescript
// JS/wysiwyg-engine/src/accessibility.ts
import type { BlockId } from "./types.js";
import type { WysiwygEngine, EngineEvent } from "./engine.js";
import { findBlockElement } from "./selection.js";

/**
 * Keeps VoiceOver-relevant attributes on each block's rendered element in sync with the model and
 * selection (design doc §8.6: "VoiceOver navigates blocks by their owner-facing manifest names —
 * the block model doubles as the accessibility model"). Never renders DOM itself — only annotates
 * elements the host's already-rendered page produced with the block-id attribute, the same
 * contract `findBlockElement` relies on elsewhere (e.g. `RichTextEditor.enter()`).
 */
export class AccessibilityAnnotator {
  #engine: WysiwygEngine;
  #displayNames: Record<string, string>;
  #root: ParentNode;
  #unsubscribeEngine: () => void;
  #unsubscribeSelection: () => void;

  constructor(engine: WysiwygEngine, displayNames: Record<string, string>, root: ParentNode = document) {
    this.#engine = engine;
    this.#displayNames = displayNames;
    this.#root = root;
    this.#annotateAll();
    this.#unsubscribeEngine = engine.onEvent((event) => this.#onEngineEvent(event));
    this.#unsubscribeSelection = engine.selection.onChange((id) => this.#onSelectionChange(id));
  }

  /** The name VoiceOver announces for `componentName` — the interim palette's display name if
   *  known, otherwise the raw component name (documented interim limitation, same as
   *  `WYSIWYGCanvasController.stubBlockPalette`'s own doc comment: a real CEM-aligned manifest
   *  replaces this once #1222's model service supplies one). */
  displayName(componentName: string): string {
    return this.#displayNames[componentName] ?? componentName;
  }

  dispose(): void {
    this.#unsubscribeEngine();
    this.#unsubscribeSelection();
  }

  #onEngineEvent(event: EngineEvent): void {
    const rerenders =
      event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model !== undefined);
    if (rerenders) this.#annotateAll();
  }

  #onSelectionChange(selected: BlockId | null): void {
    const model = this.#engine.modelSync.current;
    for (const id of model.rootIds) {
      const el = findBlockElement(id, this.#root) as HTMLElement | null;
      if (!el) continue;
      const isSelected = id === selected;
      el.setAttribute("aria-selected", String(isSelected));
      el.tabIndex = isSelected ? 0 : -1;
    }
    if (selected) (findBlockElement(selected, this.#root) as HTMLElement | null)?.focus();
  }

  #annotateAll(): void {
    const model = this.#engine.modelSync.current;
    const selected = this.#engine.selection.current;
    for (const id of model.rootIds) {
      const node = model.blocks[id];
      const el = findBlockElement(id, this.#root) as HTMLElement | null;
      if (!node || !el) continue;
      el.setAttribute("role", "group");
      el.setAttribute("aria-label", this.displayName(node.componentName));
      const isSelected = id === selected;
      el.setAttribute("aria-selected", String(isSelected));
      el.tabIndex = isSelected ? 0 : -1;
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- accessibility.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/accessibility.ts JS/wysiwyg-engine/test/accessibility.test.ts
git commit -m "feat(#1589): add VoiceOver block labeling and roving focus"
```

---

### Task 6: Wire both into `mount.ts`, post `selection-changed` to the bridge

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts`
- Modify: `JS/wysiwyg-engine/test/host/mount.test.ts`

**Interfaces:**
- Consumes: `KeyboardNavigation` (Task 4), `AccessibilityAnnotator` (Task 5)
- Produces: `window.__anglesiteWysiwygMount.mount(initialModel, displayNames?)` — note the new
  second parameter; `window.__anglesiteWysiwygKeyboardNav`, `window.__anglesiteWysiwygAccessibility` globals

- [ ] **Step 1: Write the failing tests**

Add to `JS/wysiwyg-engine/test/host/mount.test.ts` (same file, same `beforeEach` — add the two new
globals to its cleanup list too):

```typescript
it("mount() constructs KeyboardNavigation and AccessibilityAnnotator", () => {
  window.__anglesiteWysiwygMount!.mount(model, {});
  expect(window.__anglesiteWysiwygKeyboardNav).toBeDefined();
  expect(window.__anglesiteWysiwygAccessibility).toBeDefined();
});

it("unmount() disposes and clears the keyboard-nav and accessibility globals too", () => {
  window.__anglesiteWysiwygMount!.mount(model, {});
  window.__anglesiteWysiwygMount!.unmount();
  expect(window.__anglesiteWysiwygKeyboardNav).toBeUndefined();
  expect(window.__anglesiteWysiwygAccessibility).toBeUndefined();
});

it("mount() posts a selection-changed message when the engine's selection changes", () => {
  const postMessage = vi.fn();
  window.webkit = { messageHandlers: { wysiwyg: { postMessage } } };

  const engine = window.__anglesiteWysiwygMount!.mount(model, {});
  engine.selection.select(null); // no-op (already null) — proves the listener doesn't fire spuriously
  expect(postMessage).not.toHaveBeenCalled();

  document.body.innerHTML = `<p data-anglesite-block-id="b1"></p>`;
  engine.selection.select("b1");
  expect(postMessage).toHaveBeenCalledWith({ type: "selection-changed", blockId: "b1" });

  delete (window as any).webkit;
});
```

Also add `delete (window as any).__anglesiteWysiwygKeyboardNav;` and
`delete (window as any).__anglesiteWysiwygAccessibility;` to the file's existing `beforeEach`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- host/mount.test.ts` (from `JS/wysiwyg-engine/`)
Expected: FAIL — the new globals/behavior don't exist yet.

- [ ] **Step 3: Update `mount.ts`**

```typescript
import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { QualityGateChips } from "../quality-gates.js";
import { KeyboardNavigation } from "../keyboard-nav.js";
import { AccessibilityAnnotator } from "../accessibility.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygKeyboardNav?: KeyboardNavigation;
    __anglesiteWysiwygAccessibility?: AccessibilityAnnotator;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel, displayNames?: Record<string, string>) => WysiwygEngine; unmount: () => void };
  }
}

function disposeMounted(): void {
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygKeyboardNav?.dispose();
  window.__anglesiteWysiwygAccessibility?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygKeyboardNav = undefined;
  window.__anglesiteWysiwygAccessibility = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel, displayNames: Record<string, string> = {}): WysiwygEngine {
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    window.__anglesiteWysiwygKeyboardNav = new KeyboardNavigation(engine, window.__anglesiteWysiwygRichTextEditor);
    window.__anglesiteWysiwygAccessibility = new AccessibilityAnnotator(engine, displayNames);
    // Keyboard-driven (and, later, any other JS-originated) selection changes need to reach
    // `WYSIWYGCanvasController.selectedBlockId` so native Duplicate/Delete keep acting on the right
    // block (#1589) — mirrors the `contextmenu` listener below's posting convention exactly.
    engine.selection.onChange((blockId) => {
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "selection-changed", blockId });
    });
    return engine;
  },
  unmount(): void {
    disposeMounted();
  },
};

document.addEventListener("contextmenu", (event) => {
  const engine = window.__anglesiteWysiwygEngine;
  if (!engine) return;
  const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
  if (!blockId) return;
  event.preventDefault();
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- host/mount.test.ts`
Expected: PASS

- [ ] **Step 5: Run the full JS suite and typecheck**

Run: `npm run typecheck && npm test` (from `JS/wysiwyg-engine/`)
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/mount.test.ts
git commit -m "feat(#1589): mount KeyboardNavigation and AccessibilityAnnotator, post selection-changed"
```

---

### Task 7: Swift side — pass block display names into `mount()`

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift:250-263` (`mountScript(for:)`, `mountEngine()`)
- Modify: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` (the existing `mountScriptBuildsCall` test)

**Interfaces:**
- Consumes: `WYSIWYGCanvasController.blockPalette` (pre-existing, `[WYSIWYGBlockPaletteEntry]`)
- Produces: `WYSIWYGCanvasController.mountScript(for:displayNames:)` (signature change — one call site)

- [ ] **Step 1: Update the existing test for the new signature**

`Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` has a `mountScriptBuildsCall` test
around line 123-139 that builds a one-block `model`, calls `WYSIWYGCanvasController.mountScript(for: model)`,
then proves the embedded JSON round-trips back through `BlockModel` by prefix/suffix-stripping the
wrapper string. Replace the whole test body with the two-argument form — a single-key
`displayNames` dictionary keeps the assertion a plain string comparison (dictionary key order is
otherwise unspecified, which is exactly why the *old* test decoded-and-compared instead of
string-comparing — see this task's header note):

```swift
@Test("mountScript(for:displayNames:) builds a mount(...) call carrying the model's and display names' exact JSON")
func mountScriptBuildsCall() throws {
    let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 5])
    let model = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])

    let script = WYSIWYGCanvasController.mountScript(for: model, displayNames: ["p": "Paragraph"])

    let modelData = try JSONEncoder().encode(model)
    let modelJSON = try #require(String(data: modelData, encoding: .utf8))
    let namesData = try JSONEncoder().encode(["p": "Paragraph"])
    let namesJSON = try #require(String(data: namesData, encoding: .utf8))
    #expect(script == "window.__anglesiteWysiwygMount?.mount(\(modelJSON), \(namesJSON))")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGCanvasControllerTests` (needs Xcode 27 — see CLAUDE.md ▸ Build)
Expected: FAIL — `mountScript(for:)` doesn't take a second argument yet.

- [ ] **Step 3: Update `mountScript(for:)` and `mountEngine()`**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`:

```swift
/// Builds the `mount(...)` `evaluateJavaScript` string for `model` and `displayNames` — factored
/// out of `mountEngine()` so it's testable without a real `WKWebView`. `displayNames` maps
/// `componentName` -> the owner-facing name VoiceOver announces for that block
/// (`AccessibilityAnnotator`'s `displayName(_:)` on the JS side falls back to the raw
/// `componentName` for anything not in this map — see `blockPalette`'s own doc comment for why the
/// map is still a small interim stand-in). Returns a no-op script if either fails to encode
/// (unreachable in practice — both are plain `Codable`/`Encodable` values).
static func mountScript(for model: BlockModel, displayNames: [String: String]) -> String {
    guard let modelData = try? JSONEncoder().encode(model), let modelJSON = String(data: modelData, encoding: .utf8),
          let namesData = try? JSONEncoder().encode(displayNames), let namesJSON = String(data: namesData, encoding: .utf8)
    else {
        return ""
    }
    return "window.__anglesiteWysiwygMount?.mount(\(modelJSON), \(namesJSON))"
}
```

```swift
func mountEngine() {
    guard let webView else { return }
    webView.evaluateJavaScript(Self.mountScript(for: model, displayNames: blockDisplayNames))
}

/// `componentName -> displayName` built from `blockPalette` — the interim manifest stand-in
/// `AccessibilityAnnotator` (JS side) uses to label blocks for VoiceOver (#1589). Uses
/// `uniquingKeysWith:` (keeping the first entry) rather than `uniqueKeysWithValues:` — the palette
/// is a hardcoded array today, but nothing enforces distinct `componentName`s as it grows, and a
/// duplicate must not crash the whole mount call over a labeling concern.
private var blockDisplayNames: [String: String] {
    Dictionary(blockPalette.map { ($0.componentName, $0.displayName) }, uniquingKeysWith: { first, _ in first })
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS

- [ ] **Step 5: Full Swift suite + app build**

Run: `swift test --package-path .`
Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1589): pass the block palette's display names into the JS mount call"
```

---

### Task 8: WKWebView text-services acceptance check (§8.5) — manual QA

**Files:**
- None modified unless a gap is found (in which case: file a new issue for the NSTextView-overlay
  contingency — do not build it preemptively, per the design doc).

**Goal:** Verify spelling, dictation, input methods (IME), autocorrect, Services, Look Up, and
grammar work in the editable WYSIWYG canvas — the flagged-risk acceptance-checklist item from
`docs/mac-assed-app-spec.md` and design doc §8.5.

- [ ] **Step 1: Build and launch the app**

Follow `docs/testing-macos-app.md` for the full build → launch → smoke-test sequence (this session
already has Xcode 27 + xcodegen per the toolchain preflight). At minimum:

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Launch the built `.app`, open (or create) a test site, and toggle **Site ▸ Edit Page** to enter
WYSIWYG edit mode on a page with at least one paragraph/heading block.

- [ ] **Step 2: Verify each item, recording pass/fail with a concrete observation for each**

Click into a text block (Return, from Task 4's grammar, or a direct click) to enter its
contentEditable editing session, then check:

1. **Spelling** — type a misspelled word (e.g. "recieve"). Expect the standard red squiggly
   underline. Right-click it: expect system spelling-correction suggestions in the context menu.
2. **Grammar** — enable Edit ▸ Spelling and Grammar ▸ Check Grammar With Spelling; type an
   ungrammatical sentence. Expect the standard green/grammar squiggly.
3. **Autocorrect/substitutions** — type straight quotes/dashes; expect Edit ▸ Substitutions'
   smart-quotes/dashes to apply if enabled system-wide (System Settings ▸ Keyboard).
4. **Services** — select some typed text, right-click (or Edit ▸ Services submenu). Expect the
   standard macOS Services entries relevant to plain text (e.g. "Look Up", "Search With Google" if
   configured) to appear and function.
5. **Look Up** — select a word, use the standard Look Up gesture (right-click "Look Up ‹word›", or
   the system shortcut). Expect the definition popover to appear.
6. **Input methods (IME)** — switch to a non-Latin input source (e.g. Japanese Hiragana via the
   input menu) and type into the block. Expect the standard IME candidate window to appear and
   compose correctly into the contentEditable region.
7. **Dictation** — this session cannot drive a microphone; note this explicitly as an
   owner-verification item rather than claiming a pass. Everything else on this list *is*
   independently verifiable and gives strong signal about whether WKWebView's `NSTextInputClient`
   bridging is working correctly for this contentEditable region — if 1-6 all pass, dictation
   (which goes through the same text-input-client machinery) is very likely fine too, but say so
   as an inference, not a verified result.

Also confirm the app's own Edit menu isn't hiding these: `Sources/AnglesiteApp/EditMenuSkeletonCommands.swift`
adds items `before: .textEditing` (confirmed during planning) rather than `replacing:` it, so the
system's Spelling/Substitutions/Transformations/Speech items should already be present — the check
above is to confirm they also *function* against this specific contentEditable region, not just
that the menu items exist.

- [ ] **Step 2 continued: bridge/build sanity, not covered by Task 6's unit tests**

While in edit mode, also confirm end-to-end (this exercises everything Tasks 1-7 built, since JS
unit tests can't drive a real WKWebView):
- Arrow keys move a visible selection outline between blocks when no block is being text-edited.
- Return on a selected paragraph/heading enters editing (cursor appears, contentEditable active).
- Escape once (while editing) exits editing back to block-selected; Escape again clears selection.
- With VoiceOver on (⌘F5), navigating (VO+arrow or Tab, per VoiceOver's own navigation model)
  through the canvas announces each block by its palette display name ("Paragraph", "Heading") or
  raw component name for anything not in the interim palette.

- [ ] **Step 3: Record the outcome**

If every item passes (or degrades gracefully with only the noted dictation-inference caveat): no
code changes — note the verified checklist in the PR body, and tick the relevant release-acceptance
checklist item in `docs/mac-assed-app-spec.md` if it's written as an unchecked box there (read that
file's checklist section first to see its exact list format before editing).

If something concretely fails (e.g. IME composition breaks, or Services doesn't appear): do **not**
build the `NSTextView` overlay inline as part of this task. Per the design doc, that contingency is
its own scoped follow-up — file a new issue describing exactly what failed (with repro steps from
this checklist) and reference it from this PR's body instead.

- [ ] **Step 4: Commit (docs-only, if the checklist file was updated)**

```bash
git add docs/mac-assed-app-spec.md
git commit -m "docs(#1589): confirm WKWebView text-services acceptance check"
```

(Skip this commit entirely if the checklist file didn't need a change.)

---

### Task 9: Follow-up issue for Tab-walks-props, and PR prep

**Files:** None (GitHub issue + PR body only).

- [ ] **Step 1: File the Tab-walks-props follow-up issue**

Once PR2 (#1588/#1613) has merged (check `gh pr view 1613 --repo Anglesite/Anglesite` for its
state before doing this), file a new issue: "WYSIWYG: Tab walks block props (keyboard grammar,
depends on #1588's native inspector)", scoped to wiring `KeyboardNavigation`'s Tab key to move
focus into the now-real native inspector's first prop field, with Shift-Tab reversing and Escape
returning focus to the canvas. Reference #1589 and #1613/#1588 from it. If #1613 hasn't merged yet
by the time this plan's other tasks are done, still file the issue now (just note it's blocked on
#1613) rather than leaving Tab permanently untracked — CONTRIBUTING.md's "claim your issue"
convention only helps if the work has an issue to claim.

- [ ] **Step 2: Confirm the full test suite before opening the PR**

Run, in order:

```bash
swift test --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test && cd ../..
```

All must pass before proceeding (CONTRIBUTING.md ▸ Testing).

- [ ] **Step 3: Open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary / Paired PR check / Test plan).
Body must include:
- `Closes #1589`
- A summary noting the descope from the issue body (document conventions ships via #1613 instead —
  see this plan's header) and the Tab-walks-props deferral (with the follow-up issue link from
  Task 9 Step 1).
- Paired PR check: unchecked "needs a paired PR" — this is app-only (`Sources/`, `JS/wysiwyg-engine/`),
  no MCP sidecar schema change.
- Test plan: the three commands from Step 2, plus a one-line pointer to Task 8's manual
  text-services checklist result.
