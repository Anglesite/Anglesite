# WYSIWYG Mac host chrome (slice 4) — design

**Date:** 2026-08-10
**Status:** Approved, pre-plan
**Related:** Issue #1225 (this slice), epic #1221, vision spec
`docs/superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md` (§3, §8),
slice 3 design `docs/superpowers/specs/2026-08-08-wysiwyg-canvas-chrome-design.md`,
`JS/wysiwyg-engine/` (merged, slices 2–3)

## 1. Summary

Slice 4 builds the native macOS host the vision spec assigns everything outside
"the Engine" to (§3.3, §8): mounting the canvas in the real app window, a Swift
implementation of the ops protocol, and the native chrome around it — menu bar
commands, `NSUndoManager` undo, an inspector, a palette, clipboard/drag-drop, and
accessibility. Slices 2–3 (`JS/wysiwyg-engine/`, merged) built the engine entirely
against an in-memory `FixtureHost`; nothing in `Sources/` references it yet. This
slice is where the engine first meets the app.

Slice 1 (sidecar ops backend, #1222) is labeled `Blocked: human` and has not
started — it needs a paired cross-repo PR that only a human can route. Per
§3.3, the host is supposed to apply ops "via the sidecar's compiler-backed model
service" and commit to git, but that service doesn't exist yet. Following the
precedent slices 2–3 set with `FixtureHost`, this slice builds and ships against
a local `StubHostTransport` (applies ops to an in-memory model, no real git
commit) rather than blocking on #1222. Swapping in the real sidecar-backed
transport is a small follow-up PR once #1222 unblocks — the seam is the
`HostTransport`-equivalent protocol on the Swift side, not a rewrite.

This is too broad for one PR — §8.1–§8.7 span menu commands, undo, two native
panels, clipboard semantics, and accessibility. It ships as three PRs in
dependency order: **Plumbing → Panels → Polish.**

## 2. Architecture

- **Mount point:** an "Edit" toggle inside the existing `.preview` `MainPaneMode`
  (`Sources/AnglesiteApp/PreviewModel.swift`), reusing its WKWebView rather than
  adding a new pane mode. This matches the vision doc's framing — owners compose
  "directly on the true render" (§3.1); editing is the preview becoming editable,
  not a separate surface.
- **Ops bridge:** a new, dedicated `WKScriptMessageHandler` carrying
  `OpEnvelope`/`OpResult`/model-update JSON. It does not extend
  `Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift` /
  `Sources/AnglesiteBridge/WebViewBridge.swift` — those speak the older
  edit-overlay protocol (apply-edit, canvas-selection, computed-styles) that the
  block editor is meant to eventually replace (CLAUDE.md ▸ Two-repo
  coordination). Coupling new work to code slated for removal would just create
  a second migration later.
- **Swift ops types:** a `Codable` Swift enum mirroring the `Op` union in
  `JS/wysiwyg-engine/src/types.ts` (`insertBlock`, `moveBlock`, `deleteBlock`,
  `setProp`, `editText`, `setDesignToken`), JSON-serialized across the bridge.
  `OpEnvelope` carries the target content-hash version; `OpResult` carries
  `applied`/`rejected` with reason (`version-mismatch` / `invalid-target` /
  `host-error`) — mirroring the JS shapes exactly so the protocol stays one
  vocabulary, not two dialects that drift.
- **Backend:** `StubHostTransport` implements the Swift-side host contract by
  applying ops to an in-memory block-tree model only. No real source write, no
  git commit. It exists so PR1–PR3 are fully testable and reviewable now; a
  later, small PR swaps it for a sidecar-backed transport once #1222 ships.
- **Undo:** a new `WYSIWYGUndoCoordinator`, distinct from
  `Sources/AnglesiteCore/EditUndoCoordinator.swift` (which reverts git commits
  LIFO and has no real redo). Ops ship with their own inverse (mirroring JS's
  `invertOp()` in `JS/wysiwyg-engine/src/ops.ts`), so this coordinator registers
  true invertible actions with `NSUndoManager` — real redo, truthful action
  names, typing coalescing.

## 3. PR1 — Plumbing: ops flow end-to-end, menus and undo work

Goal: an op can originate from a menu command or in-canvas gesture, cross the
bridge, apply against `StubHostTransport`, and be undoable — the vertical slice
proving the whole seam works, before any panel UI exists.

- Mount the canvas + edit toggle in `PreviewModel`.
- Swift `Op`/`OpEnvelope`/`OpResult` types, the ops `WKScriptMessageHandler`, and
  `StubHostTransport`.
- Wire the existing menu skeletons rather than inventing a new convention:
  - `InsertCommands.swift` — Insert menu populated from the theme's CEM-aligned
    block manifest (owner-facing names, e.g. *Insert ▸ Testimonial*).
  - `FormatCommands.swift` — ⌘B/⌘I/⌘K route to `editText` ops when the canvas
    holds a text selection. Requires a new canvas-selection focused value
    alongside the existing `EditorFocusRegistry.swift` /
    `FocusedSite.swift:38` `focusedSceneValue` convention.
  - `ArrangeCommands.swift` — Move Block Up/Down (⌥⌘↑/↓), Duplicate (⌘D),
    Delete, enabled via the same focused-value convention.
  - Right-click on a block shows a real `NSMenu` built from the engine's
    hit-test report — never a web context menu.
- `NSUndoManager` registration via `WYSIWYGUndoCoordinator`: Edit ▸ Undo/Redo
  with truthful names ("Undo Move Block", "Undo Typing"), typing coalescing.
- Fixes slice 3's known limitation (a) (§7a of the slice 3 design): an applied
  op currently replaces the whole block subtree, disconnecting the active
  `RichTextEditor` session with no event to recover by. PR1 needs either
  finer-grained re-rendering or an explicit engine-event subscription so a
  round-trip through the host doesn't drop an in-progress edit.
- Tests: Swift unit tests for `Op` Codable round-trip, `StubHostTransport`
  apply/invert, the undo coordinator's real-redo behavior, and bridge
  encode/decode — the Swift-side analog of the JS `FixtureHost` golden tests.

## 4. PR2 — Panels: native inspector, palette, clipboard, document conventions

Goal: the chrome around the canvas becomes native, per §8.3–§8.4.

- Native inspector for typed block props (system controls: steppers, color
  wells with the system color panel, pop-up buttons), following the pattern in
  `Sources/AnglesiteApp/PageInspectorView.swift` and
  `Sources/AnglesiteApp/ComponentStyleInspectorPane.swift`. Props and their
  editor kind come from the CEM-aligned manifest.
- Native palette as a source list, dragged *from* into the canvas;
  cross-boundary drops land as `insertBlock` ops at the engine-computed index.
  Fixes slice 3's known limitation (b): `DragReorderController` is currently
  one-per-document; a host driving several breakpoint frames needs one
  controller per frame, or drop-index computation measures against the wrong
  frame's container.
- Finder/Photos drag-in → asset ingestion + image block in one gesture. AI
  alt-text proposal is stubbed/no-op here — the real proposal depends on
  on-device AI services (slice 6, #1227) and is explicitly deferred.
- Semantic paste: rich text from Pages/Word/Safari → blocks + honest inline
  runs; ⇧⌥⌘V Paste and Match Style; copying a block puts real HTML + plain text
  on the pasteboard.
- Document conventions: window title = page title with the document proxy icon
  pointing at the real `Source/` file; edited-dot tied to uncommitted ops
  (against the stub backend until #1222 lands, this reflects uncommitted
  in-memory ops rather than a real git-dirty state — noted so it isn't mistaken
  for the final behavior); native ⌘F find bar aligned with the #517 design.
- `.toolbar(id:)` so Customize Toolbar works.
- Also addresses slice 3's known limitation (c) (frame-local coordinate
  translation for overlay chrome over breakpoint iframes) where the palette/
  inspector need to draw over a specific frame.

## 5. PR3 — Polish: keyboard, VoiceOver, text services, App Intents

Goal: the acceptance-checklist items in `docs/mac-assed-app-spec.md` and the
remaining §8.5–§8.7 items.

- Keyboard-only editing grammar: arrows move block selection, Return enters
  text editing, Tab walks props, Escape exits the deepest context first
  (text → block → none).
- VoiceOver navigates blocks by their owner-facing manifest names — the block
  model doubles as the accessibility model.
- Text-services **acceptance check** (§8.5, flagged risk in the vision spec):
  verify spelling, dictation, IME, Services, and Look Up work in the editable
  WKWebView canvas content. Build the `NSTextView`-overlay contingency only if
  this check finds WKWebView insufficient — not built preemptively.
- App Intents over the ops vocabulary (e.g. "Append a post to my blog"),
  following the existing `AnglesiteIntentsTests` pattern.
- Share menu, scoped down to Quick Look on `.anglesite` packages. Real
  collaboration draft links depend on slice 7 (#1228, lands last in the epic)
  and are out of scope here.
- §8.7 (canvas renders site appearance, chrome follows system) is already true
  by construction once PR1's mount point reuses `PreviewModel`; this PR just
  confirms it on the acceptance checklist rather than implementing anything new.

## 6. Error handling

- Every op carries the model version (content hash) it targeted. On mismatch
  the host rejects with the fresh model; the engine replays or drops the
  gesture **visibly** — no silent loss (applies against `StubHostTransport`
  today, unchanged once the real backend lands).
- Failed renders (e.g. broken frontmatter from an outside edit) degrade the
  canvas to a "this page needs attention" state, never a blank webview.
- All bridge/op handling is logged, matching the "logs are sacred" convention —
  no silent failure paths, even though ops aren't a subprocess.

## 7. Testing

- **Swift:** unit tests for `Op` Codable round-trip, `StubHostTransport`
  apply/invert, `WYSIWYGUndoCoordinator` (real redo, coalescing), and bridge
  message encode/decode.
- **Cross-module:** PR1 should cover the combinations slice 3 flagged as
  spot-covered only — an edit and a reorder interleaved, and reorder inside a
  breakpoint frame — once the host actually wires those paths together (slice
  3's known limitation (d)).
- **App-level:** manual/XCUITest pass against the relevant items in
  `docs/mac-assed-app-spec.md`'s release acceptance checklist, especially the
  §8.5 text-services check in PR3.
- JS-side engine tests (`JS/wysiwyg-engine/`) are unaffected; this slice adds
  Swift-side coverage, it doesn't change the engine's own test surface.

## 8. Out of scope (deferred, not forgotten)

- Real sidecar-backed op application + git commit — waits on #1222; a small
  follow-up PR swaps `StubHostTransport` for the real transport once it ships.
- AI alt-text generation, quality-gate chips, real-time collaboration —
  slices 5–7 of the epic (#1226–#1228).
- The `NSTextView` overlay contingency for text services — built only if the
  PR3 acceptance check finds WKWebView insufficient.
- A designer/developer progressive-disclosure tier — vision spec §11 already
  rules this out; the Component Editor serves that need today.

## 9. Next steps

Write an implementation plan per PR (three plans, or one plan with three
milestones — decided at planning time) via the writing-plans skill, starting
with PR1 since PR2 and PR3 both depend on its bridge and ops types existing.
