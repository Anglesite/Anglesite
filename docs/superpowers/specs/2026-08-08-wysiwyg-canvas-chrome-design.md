# WYSIWYG canvas chrome (slice 3) — design

**Date:** 2026-08-08
**Status:** Approved, pre-plan
**Related:** Issue #1224 (this slice), epic #1221, vision spec
`docs/superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md` (§3–§5, §8),
slice 2 implementation plan `docs/superpowers/plans/2026-08-07-wysiwyg-overlay-engine-core.md`,
`JS/wysiwyg-engine/` (merged, slice 2)

## 1. Summary

Slice 3 of the modern WYSIWYG editor epic builds the interactive canvas chrome the
vision spec assigns to "the Engine" (§3.1): inline rich-text editing, drag/drop
handling for both in-canvas reordering and external (palette/Finder) drops, and
responsive breakpoint views. It extends the existing `JS/wysiwyg-engine/` package
(merged as slice 2) rather than introducing a new package or touching Swift.

Slice 1 (sidecar ops protocol / real `HostTransport`, issue #1222) is still open
and blocked on a human decision. This slice does not need it: like slice 2, it is
built and tested entirely against the in-memory `FixtureHost` and Playwright
goldens — the engine only ever talks to the abstract `HostTransport` interface.
Native integration (mounting this chrome in the real app window, the native block
palette, `NSUndoManager`, Finder file ingestion) is explicitly out of scope here —
that is slice 4, "Mac host chrome" (#1225).

## 2. Scope boundary

Mirrors slice 2's shape exactly: **pure JS/TS, zero Swift changes.** Confirmed by:

- Slice 2 shipped as an entirely JS/TS deliverable (`git log` shows only
  `feat(#1223): ...` commits under `JS/wysiwyg-engine/`); nothing in `Sources/`
  references it.
- The epic's own slice breakdown assigns menus, `NSUndoManager` undo, the native
  inspector, and the native block palette to slice 4, not slice 3.
- Spec §8.3–§8.4 describes the palette as "a native source list" and Finder-drop
  asset ingestion as host-owned — both slice-4 concerns.

Everything in this design lives in `JS/wysiwyg-engine/`, is testable via `vitest`
(unit) and Playwright (e2e goldens against a fixture host + static server), and
introduces no new runtime dependencies.

## 3. Architecture

Three new modules join the existing `src/` layout, each consuming — not
replacing — slice 2's primitives (`WysiwygEngine`, `SelectionState`, `hitTest`,
`OpQueue`, `ModelSync`):

```
JS/wysiwyg-engine/src/
├── rich-text.ts     # inline text editing: contenteditable lifecycle, honest-runs
│                     # serialization, format commands, debounced editText commit
├── drag-drop.ts      # computeDropTarget(), in-canvas reorder (moveBlock),
│                     # external drop wiring (insertBlock via host callback)
└── breakpoints.ts    # BreakpointCanvas: one shared engine driving N frame documents
```

All three route every mutation through the existing `engine.submit()` →
`OpQueue` path. None of them add new error-recovery logic — they consume the
`applied`/`rejected` events slice 2 already emits and must not swallow them
(§7).

A key existing-code finding shapes this design: `hitTest(point, doc: Document =
document)` and `computeHandleRect(id, root: ParentNode = document)` already take
an explicit document/root parameter rather than assuming the global `document`.
That lets **one `WysiwygEngine` instance (one model, one selection, one op
queue) drive multiple breakpoint frame documents simultaneously** — see §6.

## 4. Inline rich-text editing

Honest runs only: `strong`, `em`, `link` (`<a href>`), `code` — no styled spans,
matching spec §4's WYSIWYM lesson.

- **`RichTextEditor.enter(blockId)`** — sets the target text block's element
  `contenteditable="true"`, focuses it, snapshots the current `RichTextRun[]` as
  the editing baseline (used to detect no-op exits and to build the `editText`
  op's `previousRuns`).
- **Format commands** (bold/italic/link/code — spec §8.1's ⌘B/⌘I/⌘K are a
  slice-4 menu concern, but the underlying command implementation lives here) use
  **manual DOM Range wrapping/unwrapping**, not `document.execCommand` — it is
  deprecated, browser-inconsistent, and would let arbitrary style markup leak
  into the DOM. Wrapping a selection only ever produces `<strong>`, `<em>`,
  `<a href>`, or `<code>` elements; unwrapping removes them.
- **`runsFromElement(el): RichTextRun[]`** serializes the live contenteditable
  DOM into the honest-runs shape. It recognizes exactly: `strong`/`b` → strong,
  `em`/`i` → em, `a[href]` → link, `code` → code. Any other element the browser's
  contenteditable implementation might inject (a stray `<div>` from a paste, a
  styled `<span>`) is **not represented** — its text content is flattened into
  the surrounding run. This is the structural backstop for roundtrip honesty:
  even if the DOM the user produced by typing/pasting is messier than the
  recognized set, the serializer refuses to promote any of that mess into the
  ops protocol.
- **Commit timing:** debounced ~400ms after typing pauses, and immediately on
  blur, Escape, or a format command. Each commit serializes the current DOM and
  submits `{ kind: "editText", blockId, runs, previousRuns }` via
  `engine.submit()`. `previousRuns` is always the *baseline at `enter()`*, not
  the prior debounce tick — so a version-mismatch rejection mid-edit can cleanly
  discard the whole in-progress edit and re-render from the fresh model (§7)
  without needing to reconstruct intermediate state.
- **`RichTextEditor.exit()`** flushes any pending debounced commit synchronously,
  then sets `contenteditable="false"`.

## 5. Drag & drop

One geometry primitive serves two gestures.

**`computeDropTarget(point, doc): { parentId, slot, index } | null`** — walks the
block elements in `doc`, compares `point` against sibling block rects' midpoints,
and returns the nearest valid insertion target, or `null` when the point isn't
over anything droppable. Pure geometry; no DOM mutation, no op submission.

**In-canvas reorder (drag-source).** Pointer-based drag (`pointerdown` /
`pointermove` / `pointerup`), not the HTML5 Drag and Drop API — more reliable for
same-document reordering and behaves uniformly whether the block lives in a
single canvas or one of several breakpoint frames (§6). Dragging a selected
block's handle tracks `computeDropTarget` live (driving an insertion-line
indicator) and on release emits `moveBlock` from the block's current position to
the computed target.

**External drop (palette/Finder → `insertBlock`).** The canvas listens for
native `dragover`/`drop` DOM events (real OS/host-originated drags surface as
native drag events even inside a WKWebView). `dragover` calls
`computeDropTarget` for the same insertion-line feedback and calls
`preventDefault()` to allow the drop. On `drop`, **the engine does not interpret
`DataTransfer` itself** — it forwards `{ target, dataTransfer }` to a
host-supplied `onExternalDrop` callback. The host decides what block descriptor
(if any) to build — reading a custom MIME payload for a palette-originated drag,
or kicking off asynchronous Finder-file ingestion — and calls
**`submitDrop(engine, target, block): Promise<OpResult>`** (computes/validates
the target and builds+submits the `insertBlock` op) once it has one. This keeps
the engine ignorant of "what a palette item is" and "how Finder ingestion
works" — both confirmed slice-4/host concerns — while slice 3 still owns all the
real geometry, event wiring, and op construction.

## 6. Responsive breakpoint views

Breakpoints are views, not modes (spec §5): the same block model rendered at
multiple widths, all live and interactive at once — confirmed during
brainstorming that side-by-side frames should **all** be fully interactive, not
just one "active" frame with read-only mirrors.

**`BreakpointCanvas`** registers a set of `{ name: "phone" | "tablet" |
"desktop", doc: Document }` frames (in tests, N `<iframe>` documents within one
fixture page; a future host wires real iframes or its own multi-viewport
rendering — that wiring is out of scope here per §2).

- On construction, and on every `model-updated`/`applied` engine event, the same
  render function runs once per registered frame document — each frame is an
  independent DOM projection of the identical model.
- Gesture listeners (click, pointer-drag, dragover/drop) are attached
  per-frame, but each just resolves through the **one shared engine**:
  `engine.hitTest(point, thatFrame.doc)` and `engine.selection.select(id)`.
  Because selection state lives in one place, selecting a block in the phone
  frame draws handles (via `computeHandleRect(id, thatFrame.doc)`) in the
  tablet and desktop frames too, with no new cross-frame sync mechanism.
- No per-breakpoint style authoring surface exists anywhere in this module, by
  construction — every op this slice emits (`editText`, `insertBlock`,
  `moveBlock`) carries content/structure, never a breakpoint-scoped value. This
  is what "welds the iWeb trap door shut" (spec §5): the tools to create a
  desktop-only design don't exist at this layer.

## 7. Error handling

No new rejection-handling logic — every commit path in this slice
(`editText` flush, drop-triggered `insertBlock`, reorder-triggered `moveBlock`)
goes through the existing `engine.submit()` → `OpQueue`, which already:

- adopts the host's fresh model and emits a visible `rejected` event on
  version-mismatch (built in slice 2), and
- lets `WysiwygEngine` invalidate a selection that a model swap removed.

This slice's only new responsibility is **not swallowing those events**:

- An in-progress text edit whose commit is rejected discards its local draft and
  re-renders from the fresh model rather than retrying blindly — visible, per
  spec §9, never silent.
- An in-progress drag (reorder or external drop) whose target block is removed
  by a concurrent `model-updated` aborts cleanly instead of emitting a
  `moveBlock`/`insertBlock` against a now-invalid index.
- Exact user-visible presentation of a rejected/aborted gesture (toast, flash,
  etc.) is a host concern (slice 4); this slice's obligation ends at firing the
  engine event.

## 8. Testing

Mirrors slice 2's established pattern — no new test infrastructure:

- `vitest` unit tests per module. DOM-serialization logic (`runsFromElement`,
  Range wrapping) is testable under jsdom; point-based geometry
  (`computeDropTarget`, real handle rects across frames) needs a real layout
  engine, so those cases are deferred to e2e, matching how `hit-test.test.ts`
  already splits pure-traversal unit tests from Playwright-covered point
  resolution.
- New Playwright e2e goldens in `e2e/`, against the existing fixture-host +
  static-server setup:
  - `rich-text.spec.ts` — type → format → blur → `applied` `editText` event
    carrying the expected honest runs.
  - `drag-drop.spec.ts` — synthetic drag → `insertBlock`/`moveBlock` at the
    expected index; a version-mismatch mid-drag aborts visibly.
  - `breakpoints.spec.ts` — selecting in one frame shows handles in every
    registered frame; an edit applied in one frame re-renders all frames.

## 9. Out of scope (deferred to slice 4 or later)

- Mounting this chrome in the real Anglesite app window / WKWebView.
- The native block palette UI (spec §8.3's "native source list").
- `NSUndoManager` registration and typing-coalescing (spec §8.2) — this slice's
  debounced commits are what a host's undo coalescing groups, but the grouping
  itself is host-owned.
- Finder file ingestion, asset upload, AI alt-text proposals (spec §8.4, §6).
- Menu-bar commands (Insert/Format menus, spec §8.1).
- Multi-select (per slice 2's `selection.ts`, still explicitly out of scope
  unless a real need surfaces).
