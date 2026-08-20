# WYSIWYG Mac Host Chrome — PR2 (Panels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Environment note:** Tasks 1–2 both live in `Sources/AnglesiteCore` (SwiftPM, portable — no
> `canImport(Darwin)` gate). Only Task 1 is actually testable with plain
> `swift test --package-path .` on Linux, though — Task 2 depends on an `NSAttributedString`
> HTML-import API that `swift-corelibs-foundation` doesn't implement (confirmed against a live
> Swift 6.3.3 toolchain during this plan's own review), so it needs CI's macOS `swift test` lane
> even though its code lives in the portable target. Everything from Task 3 onward lives in
> `Sources/AnglesiteApp`, which `Package.swift` gates `#if compiler(>=6.4) && canImport(Darwin)` —
> invisible to `swift build`/`swift test` on a non-Darwin host at all. An implementer without local
> Xcode/macOS access can write and locally verify Task 1 only; everything else (Task 2 onward) must
> be pushed and driven to green through CI's macOS lane (`docs/testing-macos-app.md`) rather than a
> local build. This plan was authored without local Xcode access — API names/signatures cited below
> (SwiftUI `.draggable`/`.dropDestination`, `NSItemProvider`, `NSPasteboard` types) are believed
> correct for macOS 27 but **must be checked against local Xcode documentation/autocomplete before
> implementing**, not assumed correct from this doc alone.

**Goal:** Ship the native chrome the design doc's PR2 scope calls for (§4 of
`docs/superpowers/specs/2026-08-10-wysiwyg-mac-host-chrome-design.md`): a native inspector for
typed block props, a native palette as a source list, Finder/Photos drag-in, semantic paste, block
copy, and the document-conventions/toolbar items — building on PR1's merged plumbing (#1400: ops
bridge, `WYSIWYGCanvasController`, undo, menu commands) and #1222's now-merged sidecar-backed
transport (`PageModel`/`SidecarWYSIWYGHostTransport`, PRs #1603/#1609/#1595's follow-ups).

**Architecture:**

- **Inspector props gap.** The design doc says "props and their editor kind come from the
  CEM-aligned manifest," but as of this plan the sidecar's `get_page_model` response
  (`Sources/AnglesiteCore/PageModel.swift`'s `BlockInfo`) carries only `name`/`description`/
  `icon`/`slots` — no per-prop type/editor-kind schema. Rather than block PR2 on a manifest schema
  extension (a cross-repo, paired-PR change per `CLAUDE.md` ▸ "Two-repo coordination"), Task 1
  adds a **local, portable** `WYSIWYGPropEditorKind` inference function in `AnglesiteCore` that
  picks a control kind from the prop's runtime `PropValue` case plus name heuristics (`"color"`
  suffix → color well, `"src"`/`"href"`/`"url"` suffix → text field styled as a URL, `Bool` →
  toggle, `Double`/`Int`-valued `.number` → stepper, otherwise → text field). This is an
  intentionally interim stand-in — same precedent as PR1's `stubBlockPalette` — swapped for a real
  manifest-driven schema once the sidecar publishes one (file that as a follow-up issue once this
  PR lands, don't block on it here).
- **Native palette → canvas drop.** The JS engine already exposes `wireExternalDrop()`
  (`JS/wysiwyg-engine/src/drag-drop.ts:184-230`, merged in slice 3) — it wires native `dragover`/
  `dragleave`/`drop` DOM listeners on the canvas element and hands the host a computed
  `DropTarget` plus the raw `DataTransfer`; the host decides what to do and calls
  `engine.submit(...)` itself. This is the seam both the native palette drag and Finder/Photos
  drag-in should go through — **do not invent a second drop path**. A native SwiftUI `.draggable`
  drag from the palette list, dropped onto the mounted `WKWebView`, surfaces to WebKit as an
  ordinary HTML5 drag with a `DataTransfer` carrying whatever UTType payload was attached; the
  existing `wireExternalDrop` wiring (invoked from `mount.ts`, extended in Task 6) receives it like
  any other external drag. Task 6 is where `mount.ts` actually calls `wireExternalDrop` for the
  first time — PR1 never wired it up even though the JS function has existed since slice 3.
- **Finder/Photos drag-in** reuses the same `wireExternalDrop` callback (Task 8) rather than a
  parallel native `NSItemProvider` drop zone layered over the webview — simpler, and consistent
  with "the engine never interprets `DataTransfer` itself, the host does" (design doc §5). A real
  OS-level Finder/Photos drag onto a `WKWebView` surfaces as a native `drop` event with
  `DataTransfer.files`/`items` per WebKit's standard HTML5 DnD support; the host's `onDrop`
  callback (Swift, via a JS→native bridge message, not JS itself touching the filesystem) reads
  the file, copies it into the site's assets directory, and submits an `insertBlock` op for an
  image block. AI alt-text stays a stub/no-op per the design doc (depends on slice 6, #1227).
- **Semantic paste and block copy** are native `NSPasteboard` operations gated behind the canvas's
  keyboard-focus state (`WYSIWYGCanvasController.hasKeyboardFocus`, existing from PR1), mirroring
  how `FormatCommands`/`ArrangeCommands` already gate on the same flag. A new
  `WYSIWYGRichTextImporter` (portable, `AnglesiteCore`) does the actual rich-text → `RichTextRun[]`
  parsing so it's unit-testable without a live pasteboard.

---

### Task 1: `WYSIWYGPropEditorKind` inference (portable, testable on Linux)

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGPropEditorKind.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGPropEditorKindTests.swift`

**Interfaces:**
- Consumes: `PropValue` (`WYSIWYGOps.swift`, already merged).
- Produces: `enum WYSIWYGPropEditorKind: Equatable, Sendable { case toggle, stepper(range: ClosedRange<Double>?), colorWell, urlField, popUp(options: [String]), textField }`;
  `WYSIWYGPropEditorKind.infer(propName: String, value: PropValue) -> WYSIWYGPropEditorKind`.

This is the seam Task 3's inspector view switches on. Keep the heuristic table small and
documented as interim — see the header-comment note above about the missing manifest schema.

- [ ] **Step 1: Write the failing test** covering: `Bool` → `.toggle`; a prop named `"color"` or
      ending `Color` → `.colorWell` regardless of value kind; a prop named `"src"`/`"href"`/`"url"`
      (case-insensitive suffix match) → `.urlField`; a `.number` value with a non-color/url name →
      `.stepper(range: nil)`; anything else (`.string`, `.object`, `.array`, `.null`) → `.textField`.
      Also test precedence: a `Bool`-valued prop named `"color"` still gets `.colorWell` (name
      heuristics win over value-kind heuristics, since `"showColor"` as a raw string wouldn't tell
      an owner anything useful as a bare toggle).
- [ ] **Step 2: Run `swift test --filter WYSIWYGPropEditorKindTests`, confirm it fails** (type
      doesn't exist).
- [ ] **Step 3: Implement** `infer(propName:value:)` per the heuristic table above.
- [ ] **Step 4: Run the filter again, confirm it passes.**
- [ ] **Step 5: Commit** — `docs(#1588): add WYSIWYG prop editor kind inference` (not `feat`/`fix`
      scoped to `#1588` if this PR isn't the one closing it; see CONTRIBUTING.md's commit-scope/
      closing-keyword note — use the PR's own eventual number once opened, or a non-closing type).

---

### Task 2: `WYSIWYGRichTextImporter` — rich text → `RichTextRun[]` (portable SwiftPM target, macOS-only)

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGRichTextImporter.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGRichTextImporterTests.swift`

**Interfaces:**
- Consumes: `RichTextRun` (`WYSIWYGOps.swift`).
- Produces: `WYSIWYGRichTextImporter.importHTML(_ html: String) -> [RichTextRun]`;
  `WYSIWYGRichTextImporter.importPlainText(_ text: String) -> [RichTextRun]` (Paste and Match
  Style — a single `.text` run, matching `RichTextRun.Kind.text`).

`importHTML` is a **deliberately narrow** HTML→runs converter: it needs to recognize only the
inline vocabulary `RichTextRun.Kind` already models (`strong`/`b`, `em`/`i`, `a[href]`, `code`,
plain text) and flatten everything else (headings, lists, `<div>`, images, styles) to their text
content, dropping structure the block model doesn't represent yet. This is not a general HTML
parser — use `Foundation`'s `NSAttributedString(data:options:documentAttributes:)` with
`.documentType: .html` to get a structured attributed string, then walk its runs and map
`NSFontDescriptor` bold/italic traits and `.link` attributes onto `RichTextRun.Kind`, matching the
exact same "honest runs" contract `JS/wysiwyg-engine/src/rich-text.ts` already established for the
engine side (don't invent a second inline vocabulary — every case here must round-trip through the
existing `RichTextRun` type unchanged).

**Confirmed against a live Swift 6.3.3 toolchain (PR #1612 review):** unlike Task 1, this task is
**not** runnable on Linux — `swift-corelibs-foundation`'s `NSAttributedString` doesn't carry
`NSAttributedString.DocumentType`/HTML-import support at all (`no exact matches in call to
initializer`); it's historically an Apple-platforms-only capability (implemented via WebKit
internals under plain `import Foundation` on macOS, no `import AppKit` needed there, but absent on
Linux and not reliable on iOS). It still belongs in the portable `AnglesiteCore` target and still
gets real `swift test` coverage — just from CI's **macOS** `swift test` lane
(`AnglesiteCoreTests`), not from a Linux host or from this plan's own local verification. An
implementer without macOS/Xcode access can write this task's code and tests, but can't execute them
locally the way Task 1's are executable; treat it like every `Sources/AnglesiteApp` task below —
push and let CI confirm it.

- [ ] **Step 1: Confirm the initializer's actual availability first**, before writing any test
      against it — check whether `NSAttributedString.DocumentType.html` is reachable from
      `AnglesiteCore` (no `import AppKit`) on the target macOS SDK via local Xcode docs/autocomplete
      (or, if only Linux is available, at minimum confirm CI's macOS lane is what will validate
      this, per the note above). If it turns out to require `AppKit`/`Cocoa` after all, move this
      file into `AnglesiteAppCore` instead (`Sources/AnglesiteApp`, Task 3's target) before writing
      Step 2's tests — deciding the target after the tests are written risks a wasted round-trip if
      the module turns out wrong.
- [ ] **Step 2: Write the failing tests** — `<p><strong>Bold</strong> and <em>italic</em> and
      <a href="https://x">link</a></p>` → three/four runs with the right kinds and `href`; a
      `<h1>`/`<ul><li>` gets flattened to plain-text runs (structure dropped, text kept); nested
      `<strong><em>` produces a run whose `children` carries the inner kind (matches
      `RichTextRun.children`'s existing shape from Task 1 of the plumbing plan); plain-text import
      wraps the whole string in one `.text` run verbatim (no trimming/collapsing — Paste and Match
      Style should be a faithful plain-text drop, not a lossy one).
- [ ] **Step 3: Run `swift test --filter WYSIWYGRichTextImporterTests` on macOS (CI or local Xcode),
      confirm failure.**
- [ ] **Step 4: Implement** using `NSAttributedString(data:options:documentAttributes:)` per Step 1's
      confirmed target.
- [ ] **Step 5: Run tests on macOS, confirm pass.**
- [ ] **Step 6: Commit.**

---

### Task 3: Native inspector panel — typed prop editors

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGBlockInspectorView.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGBlockInspectorViewTests.swift` (model-level only — SwiftUI
  view bodies aren't directly unit-testable; test the binding/submit logic a `@Observable` view
  model exposes, matching how `PageInspectorView.swift`'s `InspectorEditorModel` types are tested
  rather than the view itself).

**Interfaces:**
- Consumes: `WYSIWYGCanvasController` (`model`, `selectedBlockId`, `submit(_:)`), `PropValue`,
  `WYSIWYGPropEditorKind` (Task 1).
- Produces: `struct WYSIWYGBlockInspectorView: View`; a small `@Observable` view-model type (name
  TBD at implementation time, e.g. `WYSIWYGBlockInspectorModel`) that reads the selected block's
  `props` from `controller.model` and turns each into a `(name, WYSIWYGPropEditorKind, PropValue)`
  row, submitting `.setProp` ops on edit (debounced for text fields, immediate for toggles/steppers
  — matches `ComponentStyleInspectorPane`'s existing debounce pattern for text edits, see that
  file's `commitDeclaration` call sites).

Follow `PageInspectorView.swift`'s `InspectorChrome` structure (header + form, `.id(...)`-keyed on
the selected block so per-field `@State` doesn't leak across selection changes — same reasoning as
`PageInspectorView`'s own `.id(context.id)`, see that file's header comment) and
`ComponentStyleInspectorPane.swift`'s control patterns (`ColorPicker` binding at line 173, `Picker`
for enum-like props). Empty state (no block selected, or the selected block has no props) shows a
plain "No block selected" / "This block has no editable properties" message, not a blank pane —
matches `GenericPageInfoForm`'s "can't be edited yet" precedent rather than an empty form.

- [ ] **Step 1: Write the view-model tests** — given a `WYSIWYGCanvasController` with a selected
      block carrying `["title": .string("Hi"), "featured": .bool(true)]`, the model produces two
      rows in prop-name order with the right inferred kinds; editing the toggle row submits
      `.setProp(blockId:, propName: "featured", value: .bool(false), previousValue: .bool(true))`
      through the controller and the controller's `model` reflects it (use
      `StubWYSIWYGHostTransport` as the controller's transport, same as
      `WYSIWYGCanvasControllerTests` already does).
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement the view model**, then the SwiftUI view using system controls per kind:
      `Toggle` for `.toggle`, `Stepper` (with `Slider` as a secondary control when `range` is
      non-nil) for `.stepper`, `ColorPicker` for `.colorWell` (parse/serialize the prop's string
      value as a hex color — reuse whatever helper `ComponentStyleInspectorPane` already has for
      this rather than writing a second one; check that file for an existing hex↔Color
      conversion before adding a new one), a `TextField` styled with a link/globe icon for
      `.urlField`, plain `TextField` otherwise.
- [ ] **Step 4: Wire into the existing inspector split** — find where the app's right-hand
      inspector pane picks between `PageInspectorView`/`ComponentStyleInspectorPane`/etc. (likely
      `SiteWindow.swift`'s or `InspectorPane`-equivalent's `switch` over the current selection
      context) and add a case for "WYSIWYG canvas has a block selected" that shows
      `WYSIWYGBlockInspectorView` instead. Read that switch site's existing structure before
      adding a case — don't guess its shape without reading it first.
- [ ] **Step 5: Run view-model tests, confirm pass. Commit.**

---

### Task 4: Native palette source list + `Transferable` drag payload

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGBlockPaletteView.swift`
- Create: `Sources/AnglesiteApp/WYSIWYGBlockPaletteEntry+Transferable.swift` (or fold into the
  palette view file if small enough — implementer's call)
- Test: `Tests/AnglesiteAppTests/WYSIWYGBlockPaletteEntryTransferableTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGCanvasController.blockPalette` (`[WYSIWYGBlockPaletteEntry]`, existing from
  PR1).
- Produces: `extension WYSIWYGBlockPaletteEntry: Transferable` (custom `UTType`, e.g.
  `"io.dwk.anglesite.wysiwyg-palette-entry"`, added to `Info.plist`'s exported UTIs or declared
  inline via `UTType(exportedAs:)` — check how the existing `io.dwk.anglesite.site` UTI is declared
  in `project.yml`/`Info.plist` and follow the same convention); `struct WYSIWYGBlockPaletteView:
  View` — a `List` of `blockPalette` entries (name + icon from... there is no icon on
  `WYSIWYGBlockPaletteEntry` today; add one, or fall back to a generic "square.stack" SF Symbol
  until the manifest supplies real icons, matching `PageModel.BlockInfo.icon`'s already-optional
  shape), each row `.draggable(entry)`.

Replaces the Insert-menu-only interim palette (PR1 Task 12) as the *primary* way to add a block —
the Insert menu commands stay (menu-bar IA still needs them for keyboard-only/VoiceOver use per
PR3's scope), but this view is the new default-visible palette panel.

- [ ] **Step 1: Write the failing `Transferable` round-trip test** — encode a
      `WYSIWYGBlockPaletteEntry` via its `Transferable` conformance (using
      `ProxyRepresentation`/`CodableRepresentation` per whichever approach the implementation
      picks — `WYSIWYGBlockPaletteEntry` is already `Sendable`, add `Codable` if using
      `CodableRepresentation`) and decode it back, confirming `kind`/`componentName` survive.
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement** the `Transferable` conformance and the `List` view.
- [ ] **Step 4: Wire into the app** — find the existing palette mount point (likely a new toolbar
      panel or a tab in the same inspector split Task 3 extends; the design doc doesn't mandate a
      specific placement, so follow whatever `docs/mac-assed-app-spec.md`'s window-chrome
      conventions suggest for a "source list" — check that spec's relevant section before deciding
      placement).
- [ ] **Step 5: Run tests, confirm pass. Commit.**

---

### Task 5: Palette drop → `insertBlock` (native drag lands in the JS canvas)

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (or a new small extension file if
  the implementer prefers keeping the controller file from growing further)
- Modify: `JS/wysiwyg-engine/src/host/mount.ts` (wire `wireExternalDrop`, see Task 6 — this task
  and Task 6 are sequenced together in practice since a drop can't be tested without the wiring;
  kept as separate tasks here only because the payload-shape work (this task) and the DOM-wiring
  work (Task 6) are independently reviewable)
- Test: `JS/wysiwyg-engine/test/host/mount.test.ts` (new or extended) +
  `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerPaletteDropTests.swift`

**Interfaces:**
- Consumes: `wireExternalDrop` (`drag-drop.ts`, existing), `WYSIWYGCanvasController.insertBlock(_:)`
  (existing, currently only callable from the Insert menu).

A native `.draggable` payload dropped onto a `WKWebView` surfaces as a `DataTransfer` carrying
whatever representation `Transferable` serialized (Task 4) — typically as a custom-type string or
file promise depending on which `Transferable` representation was chosen. The `onDrop` handler
`mount.ts` passes to `wireExternalDrop` needs to recognize this specific payload (by UTType /
MIME-ish key in `DataTransfer.types`) and, when present, **not** try to build a block in JS at all
— instead post a native bridge message (new `WYSIWYGOpsDispatcher` message type, or reuse
`submit-op` if the JS side can resolve the palette entry to a real `Op` itself from the transferred
data — decide at implementation time based on what's actually in the `DataTransfer` once this is
prototyped against a real WKWebView, which needs Xcode). Document whichever shape is chosen in this
file's own header comment once decided, since this doc can't verify the exact `DataTransfer`
payload shape without a live macOS/WebKit session.

- [ ] **Step 1: Write a Swift-side test** asserting `WYSIWYGCanvasController.insertBlock(_:)`
      (existing) is reachable/callable from wherever the drop-handling code ends up — this task's
      real risk is on the JS/WebKit side (untestable without Xcode), so keep the Swift-side
      contribution narrow and well-covered, and treat the JS wiring as the part needing manual
      verification during PR review.
- [ ] **Step 2–4: Implement, following whichever payload shape Step 0's live prototyping settles
      on.** Flag in the PR description that this task's DataTransfer-shape assumption needs
      confirming against a real WKWebView session before merge.
- [ ] **Step 5: Commit.**

---

### Task 6: Wire `wireExternalDrop` into `mount.ts` (first real use since slice 3)

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts`
- Test: `JS/wysiwyg-engine/test/host/mount.test.ts`

**Interfaces:**
- Consumes: `wireExternalDrop` (existing, `drag-drop.ts:184`).
- Produces: `mount()` (existing, `mount.ts`) additionally calls `wireExternalDrop(canvasEl, ...)`
  once the canvas element is known, storing the disposer for `unmount()` to call — mirrors how
  `mount.ts` already tracks the engine/rich-text-editor globals for teardown.

This is genuinely small in isolation but is the task that makes Task 5 (palette drop) and Task 8
(Finder/Photos drop) both possible — neither drop path exists until this wiring lands. Route
`onDrop`'s callback through a small dispatch that inspects `dataTransfer.types` and delegates to
whichever of Task 5 / Task 8's handling applies (palette-entry UTType vs. `Files`/image UTTypes) —
write this dispatch here, even though the two branches' actual logic is implemented in Tasks 5 and
8, so this task's tests can assert the *routing* decision without needing either branch's real
implementation yet (stub both branches as no-ops for this task's own tests, then Tasks 5/8 replace
the stubs).

- [ ] **Step 1: Write failing tests** — a synthetic `drop` event with `dataTransfer.types`
      containing the palette UTType routes to the (stubbed) palette handler; one with `Files`
      routes to the (stubbed) Finder handler; an unrecognized type is ignored (no throw, no
      submitted op) per the "no silent-but-wrong action" bar, though silently ignoring an
      unrecognized drag is the *correct* behavior here, not a violation of it — a drag the canvas
      doesn't understand should just not accept the drop, which is what "not calling `onIndicator`/
      `onDrop`'s inner logic" already does by construction.
- [ ] **Step 2–4: Implement per above.**
- [ ] **Step 5: `npm run lint && npm run typecheck && npm test` in `JS/wysiwyg-engine/`, confirm
      clean. Commit.**

---

### Task 7: Block copy — real HTML + plain text on the pasteboard

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockSerializer.swift` (portable — HTML/plain-text
  rendering from a `BlockNode` is pure data transformation, no AppKit needed)
- Test: `Tests/AnglesiteCoreTests/WYSIWYGBlockSerializerTests.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` or a new `WYSIWYGCopyCommand.swift`
  (native `NSPasteboard` write, App-target since `NSPasteboard` is AppKit)

**Interfaces:**
- Consumes: `BlockNode`, `RichTextRun` (existing).
- Produces: `WYSIWYGBlockSerializer.renderHTML(_ node: BlockNode, model: BlockModel) -> String`;
  `WYSIWYGBlockSerializer.renderPlainText(_ node: BlockNode, model: BlockModel) -> String`
  (recursively resolves `node.slots` children from `model.blocks`); an Edit ▸ Copy handler (or
  extends the existing focus-scoped Edit-menu wiring `ArrangeCommands.swift` already established
  in PR1) that, when the canvas holds keyboard focus and a block is selected, writes both
  representations to `NSPasteboard.general` instead of falling through to whatever default Copy
  behavior currently applies (likely none, today, for a WYSIWYG selection).

`renderHTML`/`renderPlainText` are the inverse direction of Task 2's `importHTML` — both should
agree on what `RichTextRun.Kind` maps to which HTML tag (`strong`→`<strong>`, not `<b>`, etc.), so
a copy-then-paste round-trip inside the app is lossless. Consider whether `Task 2` and this task
should share a small `RichTextRun.Kind ↔ HTML tag name` mapping table rather than each hand-rolling
one — check when implementing this task, since Task 2 lands first.

- [ ] **Step 1: Write failing tests** — a text block with mixed `strong`/`em`/plain runs renders to
      the expected `<p>` HTML and matching plain text; a block with an `astro`/`custom-element` kind
      renders using `componentName` as a best-effort tag name (document this as a known
      simplification — real Astro component serialization is out of scope, this is clipboard
      interop, not the site's actual build output); a block with slot children recursively includes
      them in document order.
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement `WYSIWYGBlockSerializer`.**
- [ ] **Step 4: Wire the Edit ▸ Copy handler** — write `NSPasteboard.general.declareTypes([.html,
      .string], owner: nil)` then `setString`/`setData` for each per standard `NSPasteboard`
      HTML-writing convention (verify `.html` pasteboard type name/UTI against current AppKit docs
      — this doc can't confirm the exact API surface without Xcode).
- [ ] **Step 5: Run tests, confirm pass. Commit.**

---

### Task 8: Finder/Photos drag-in → asset ingestion + image block

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts` (Task 6's Finder-drop branch)
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGAssetIngestor.swift` (protocol +
  filesystem-backed implementation — copies a dropped file into the site's assets directory under
  a collision-safe name, returns the project-relative path to use as the new image block's `src`
  prop)
- Test: `Tests/AnglesiteCoreTests/WYSIWYGAssetIngestorTests.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (a new
  `insertImageBlock(assetPath:)` or similar, parallel to existing `insertBlock(_:)`)

**Interfaces:**
- Consumes: nothing new on the JS side beyond Task 6's routing.
- Produces: `protocol WYSIWYGAssetIngestor: Sendable { func ingest(sourceURL: URL, into
  assetsDirectory: URL) async throws -> String }` (portable, testable with a temp directory —
  no AppKit needed for the copy itself); a concrete `FileManagerAssetIngestor`.

The Swift-side asset copy is portable and fully testable without Xcode (`FileManager` is
cross-platform). The part this doc cannot verify without a live WKWebView session is **how the
dropped file's `URL` actually reaches Swift** from a WebKit `DataTransfer.files` entry — recent
WebKit exposes dropped files as `File` objects with real byte access (`file.arrayBuffer()`), not
directly as filesystem `URL`s, so the JS-side handler likely needs to read bytes and post them
(base64 or a `Blob` URL) across the bridge rather than passing a path — verify this against a real
WKWebView before assuming a `URL` is available natively. Photos drag-in (vs. Finder) may present
differently (a promise-based `NSItemProvider` rather than a materialized file) — same caveat.
**This task carries the most execution risk in the plan and should be prototyped against a live
app before the surrounding tasks are considered committed to this exact shape.**

- [ ] **Step 1: Write failing tests for `FileManagerAssetIngestor`** — ingesting a file into an
      assets directory that already has a same-named file produces a collision-safe rename (e.g.
      `photo.jpg` → `photo-1.jpg`), not an overwrite or throw; the returned path is
      project-relative, not absolute.
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement `FileManagerAssetIngestor`.**
- [ ] **Step 4: Prototype the JS↔native byte-transfer path against a live app build** (needs
      Xcode/macOS — flag as a manual step in the PR, not something CI validates for you) and wire
      `insertImageBlock`. AI alt-text stays a stub per the design doc.
- [ ] **Step 5: Run ingestor tests, confirm pass. Commit.**

---

### Task 9: Semantic paste (⌘V and ⇧⌥⌘V)

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGPasteCommands.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGPasteCommandsTests.swift` (test the routing/model-update
  logic against `WYSIWYGRichTextImporter`, not a real `NSPasteboard` — inject a small
  pasteboard-reading protocol so a fake can supply HTML/plain-text content in tests, same pattern
  as `WYSIWYGHostTransport` being a protocol so `StubWYSIWYGHostTransport` can stand in)

**Interfaces:**
- Consumes: `WYSIWYGRichTextImporter` (Task 2), `WYSIWYGCanvasController.submit(_:)` (existing).
- Produces: Edit ▸ Paste (⌘V) reads `NSPasteboard.general`'s HTML representation if present, runs
  it through `importHTML`, and submits an `.editText` op (if a text block/run is the active
  target) or a sequence of `.insertBlock` ops (if pasting into an empty selection — decide the
  exact block-vs-text-target disambiguation at implementation time based on what
  `RichTextEditor`'s existing active-element tracking (`JS/wysiwyg-engine/src/rich-text.ts`,
  referenced from `WYSIWYGCanvasController.applyFormat`) already knows); ⇧⌥⌘V (Paste and Match
  Style) always uses `importPlainText` regardless of what representations are on the pasteboard.

Gate both behind `hasKeyboardFocus`, matching every other canvas-focused command in this file.

- [ ] **Step 1: Write failing tests** — a fake pasteboard with HTML content routes through
      `importHTML`; a fake pasteboard with only plain text (no HTML representation) also works via
      `importPlainText` as a fallback for plain ⌘V, not just ⇧⌥⌘V; ⇧⌥⌘V ignores available HTML and
      always uses plain text even when HTML is present.
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement**, including the pasteboard-reading protocol seam mentioned above.
- [ ] **Step 4: Wire ⌘V/⇧⌥⌘V key equivalents** — check how `FormatCommands.swift`/
      `ArrangeCommands.swift` register their key equivalents (PR1) and follow the same menu-command
      convention rather than a raw `NSEvent` monitor.
- [ ] **Step 5: Run tests, confirm pass. Commit.**

---

### Task 10: Document conventions — proxy icon, edited-dot, ⌘F find bar

**Files:** TBD at implementation time — likely `Sources/AnglesiteApp/SiteWindow.swift` (window
title/proxy-icon wiring) and wherever `PreviewModel`/`WYSIWYGCanvasController` expose an
"uncommitted ops" count.

**Scope, per design doc §4:**
- Window title = page title, document proxy icon (`NSWindow.representedURL`) pointing at the real
  `Source/` file the open page corresponds to.
- Edited-dot (`NSWindow.isDocumentEdited`) tied to whether `WYSIWYGCanvasController` has any
  applied-but-uncommitted ops. Note the design doc's own caveat: against the stub/sidecar transport
  today this reflects in-memory ops, not real git-dirty state, until #1222's real commit path is
  fully wired end-to-end — don't let the edited-dot's meaning silently drift from that documented
  caveat.
- Native ⌘F find bar aligned with the #517 design (`docs/superpowers/specs/` — locate the #517
  find-bar spec/plan and match its established pattern rather than inventing a second one; PR
  #1273 already wired Edit ▸ Find into the Component Editor's Source pane along these lines —
  read that PR's diff as the closest precedent before implementing this task).

This task is scoped loosely (no test-first steps written) because it depends on reading
`SiteWindow.swift`'s current window-chrome wiring first, which this plan (authored without a full
repo read of that file) can't fully anticipate. **Read `SiteWindow.swift` and PR #1273's diff
before starting this task**, then write it TDD per the same pattern as every other task in this
plan: failing test first where the logic is testable (edited-dot state, proxy-icon URL resolution)
and manual verification for the parts that are purely `NSWindow` chrome.

- [ ] **Step 1: Read `SiteWindow.swift`'s current window-title/proxy-icon logic and PR #1273's
      find-bar precedent.**
- [ ] **Step 2: Write failing tests for the testable parts** (edited-dot boolean derivation from
      "any uncommitted ops," proxy-icon URL resolution from the open page's known `Source/` path).
- [ ] **Step 3–4: Implement, following the read precedents.**
- [ ] **Step 5: Commit.**

---

### Task 11: `.toolbar(id:)` for Customize Toolbar

**Files:** `Sources/AnglesiteApp/SiteWindow.swift` (or wherever the window's `.toolbar` modifier
currently lives).

- [ ] **Step 1: Read the current `.toolbar` modifier call site.**
- [ ] **Step 2: Add `.toolbar(id:)` with stable per-item `.id(...)`s** so Customize Toolbar works,
      per design doc §4. No new testable logic — this is pure SwiftUI toolbar configuration;
      verify manually (Customize Toolbar sheet opens, items can be added/removed/reordered and the
      arrangement persists across a relaunch) rather than writing a test for it.
- [ ] **Step 3: Commit.**

---

## Testing summary

- **Swift, portable (`AnglesiteCore`), fully verifiable on Linux:** Task 1, 7's serializer, 8's
  asset ingestor. These can be implemented and fully verified without Xcode.
- **Swift, portable (`AnglesiteCore`), but macOS-only at test time:** Task 2 — its code has no
  `canImport(Darwin)` gate, but its `NSAttributedString` HTML-import dependency doesn't exist in
  `swift-corelibs-foundation`, so its tests only run on CI's macOS lane (or local Xcode).
- **Swift, App-target (`Sources/AnglesiteApp`, macOS/Xcode-only):** Tasks 3, 4, 5's Swift half, 7's
  pasteboard-write half, 9, 10, 11. Model/view-model logic within these should still be unit-tested
  (per each task's Step 1) even though the test *run* needs a Darwin host — write the tests as part
  of the task, don't defer them, even if you personally can't execute them locally.
- **JS (`JS/wysiwyg-engine/`):** Tasks 5's routing test, 6, 8's mount.ts wiring. `npm run lint &&
  npm run typecheck && npm test` per CONTRIBUTING.md.
- **Manual/App-level (needs a live build):** Task 5's DataTransfer payload shape, Task 8's
  JS↔native byte-transfer path, Task 10's find-bar/proxy-icon/edited-dot behavior, Task 11's
  Customize Toolbar persistence. Flag these explicitly as unverified-by-CI in the eventual PR body
  under Test plan, per CONTRIBUTING.md's honest test-plan convention (see e.g. PR #1564's Test plan
  section, which marks a step "not run" with a stated reason rather than checking it off).

## Sequencing note

Tasks 1–2 have no dependency on anything else and are the safest starting point for an implementer
without local macOS access, though only Task 1 is actually locally verifiable there — Task 2's code
can be written the same way but its tests need CI's macOS lane. Tasks 3–4 depend on 1 (and 4 doesn't
depend on 3, so they can run in parallel). Tasks 5–6 are tightly coupled (see Task 5's note) and
should land together or in immediate succession. Task 7 depends only on already-merged PR1 types.
Task 8 depends on Task 6's routing existing, and carries this plan's highest execution-risk item
(the JS↔native file-transfer shape) — consider prototyping it early, even out of order, to avoid
discovering a wrong assumption late. Task 9 depends on Task 2. Tasks 10–11 are independent of
everything else and can land whenever convenient.

Given the volume (11 tasks spanning two languages and a hard macOS/Xcode dependency for most of
it), consider whether this still ships as one PR per the original design doc's PR2 scope, or
whether it's worth splitting further (e.g., "PR2a: inspector + palette + copy" vs. "PR2b: drag-in +
paste + document conventions") once Tasks 1–2 land and the remaining scope's actual size is
clearer. The design doc's own §9 already anticipated re-splitting slice 4 once at the PR1/PR2/PR3
boundary; nothing prevents doing it again here if warranted.
