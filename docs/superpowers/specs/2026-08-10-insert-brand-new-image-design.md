# Insert a brand-new image — design

**Date:** 2026-08-10
**Status:** Approved, pre-plan
**Related:** Issue #1408 (this work), #81 (App Store container smoke test's
"Example photo" checklist row), #32 (closed — shipped the replace-only drag-drop
pipeline this issue extends), #496 (closed epic — Component Editor write path),
#960 (disabled-`PlannedItem` UX, orthogonal)

## 1. Summary

Today there is no way to add a first image to a page that has none:

1. The overlay's drag-drop handler (`attachImageDrop` in
   `JS/edit-overlay/src/overlay.ts`) only lets you drop onto an *existing*
   `<img>` to replace it. A page with zero images always shows "This page has
   no images to replace."
2. `Insert ▸ Image` (`Sources/AnglesiteApp/InsertCommands.swift`) is a
   permanently-disabled `PlannedItem` — there is no write path behind it at all.

This closes both gaps with **one new sidecar op**, `insert-image`, that both
entry points call.

Two candidate write paths already exist in the codebase and were evaluated:

- `WYSIWYGCanvasController.insertBlock` (block-model ops, already wired for the
  Insert ▸ Component submenu) — **not usable yet**. Its backend,
  `WYSIWYGHostTransport`, is an in-memory stub pending #1222 (itself
  `Blocked: human`, unstarted). Wiring Insert ▸ Image through it would look
  done without writing anything real.
- `insert-node` / `ComponentStructureEditBuilder` (AST-node ops, real,
  MCP-backed via `MCPApplyEditRouter`) — real, but (a) scoped app-side to
  `EditorKind.component` files only (`src/components/*.astro`), even though the
  sidecar's `component-structure-edit.mjs` itself works on any `.astro` file
  (`validPath()` only checks the extension), and (b) `insert-node`'s `NodeSpec`
  has no way to set an initial `src` attribute, and no existing op writes a
  *new* image asset — `replace-image-src` only mutates an existing `<img>`'s
  `src`.

Neither path supports "insert a new image" as-is. Rather than chain
`insert-node` (bare `<img>`) → refetch the component model → `set-attr` (a
second round-trip with its own staleness window), this adds one atomic op that
does the asset write and the node insert together.

## 2. Architecture

```
Overlay drop (no existing <img>)  ──┐
                                      ├──> EditMessage{op: "insert-image", …} ──> MCPApplyEditRouter ──> plugin apply_edit tool
Insert ▸ Image (NSOpenPanel)     ──┘                                                      │
                                                                                            v
                                                                          insert-image dispatcher branch
                                                                          (server/apply-edit-dispatcher.mjs,
                                                                           anglesite-skills repo)
                                                                                            │
                                                              ┌─────────────────────────────┼─────────────────────────────┐
                                                              v                                                            v
                                                  processImageDrop() — REUSED VERBATIM                          insertion-point resolver
                                                  (write dataURL → public/images/,                              (new — reuses
                                                   optimizeImage, build srcset;                                  resolveAllSpans /
                                                   already tolerates "no current src",                           resolveInsertionOffset
                                                   falls back to the dropped file's own stem)                    from component-structure-edit.mjs)
                                                              │                                                            │
                                                              └──────────────────> splice <img src=… srcset=… alt=…> ──────┘
                                                                                            │
                                                                                            v
                                                                          {file, range, replacement} — same shape every
                                                                          other apply-edit op returns; existing patch/
                                                                          commit/git-branch machinery applies unchanged
```

## 3. Sidecar (`Anglesite/anglesite-skills`) — new `insert-image` op

**Ships first, as a paired PR, tagged and released before the app PR can
consume it (`CONTRIBUTING.md` ▸ "Paired PRs").**

- Add `"insert-image"` to the closed `op` enum in `server/apply-edit-schema.mjs`
  (alongside `replace-image-src`, `insert-node`, etc.), with a payload of
  `{ path, selector?, value: {filename, mimeType, dataURL, alt?} }`. No
  `component` payload — this is schema-compatible with the existing
  `EditMessage` shape used by `replace-text`/`replace-attr`/`replace-image-src`,
  plus an optional `alt` string in `value`.
- `server/apply-edit-dispatcher.mjs`: new branch that calls the existing
  `processImageDrop(projectRoot, edit)` **unchanged** — it already falls back
  to the dropped filename's stem when `selector.textContent` doesn't resolve
  to a matchable existing `/images/...` path (verified by reading
  `server/apply-edit-dispatcher.mjs:113-181`), which is exactly the "no prior
  image" case.
- New insertion-point resolution (new function, colocated with
  `component-structure-edit.mjs` since it reuses that file's
  `resolveAllSpans`/`resolveInsertionOffset`/`escapeAttr` exports):
  - When `selector` is present: locate the matching element in the template
    (reuse the tag/attribute matching `resolveAstro`'s existing selector-based
    ops already do) and insert the built `<img>` tag as its **last child**.
  - When `selector` is absent (the menu entry point — no natural DOM anchor):
    insert at the end of the template's root content, mirroring how
    `WYSIWYGCanvasController.insertBlock` already defaults to "append at page
    root."
  - No match for a given `selector` → `refuse("no-match", …)`, same
    contract every other selector-based op already follows.
- Reply: reuse `EditReply`'s existing `result: {src, srcset}` shape
  (`replace-image-src`'s shape) so both app-side call sites share one
  "what do I do with a successful image op" handler.
- Tests mirror `replace-image-src`'s existing coverage: selector-anchored
  insert, no-selector root-append insert, no-match selector, non-image file,
  oversized/corrupt data URL.

## 4. App (`Anglesite/Anglesite`) — two call sites, one new op constant

Blocked on the sidecar PR merging and its image being re-vendored
(`scripts/vendor-container-image.sh`) before this can land, per
`CONTRIBUTING.md`.

- **`EditMessage.Op.insertImage = "insert-image"`** — new constant next to the
  existing op names in `Sources/AnglesiteCore/EditMessage.swift`.
- **Overlay drop-insert branch**
  (`JS/edit-overlay/src/overlay.ts`'s `attachImageDrop`):
  - `showTargets()`: when `imageTargets()` is empty, instead of the "no images
    to replace" hint, highlight a designated content region (`<main>`, or the
    template's primary content container — not literally any element on the
    page, so the drop target stays predictable) as an *insert* target, using
    the existing `IMAGE_DROP_TARGET_CLASS`/hint machinery.
  - `drop` handler: reuses the existing reader/timeout/optimistic-update/revert
    scaffolding `replace-image-src` already has. Posts
    `op: EditMessage.Op.insertImage` with the container's
    `elementInfoFor(container)` as `selector`. No prior `src` to revert to on
    failure — a failed insert just removes the optimistic DOM node rather than
    restoring an old `src`.
  - `imageTargets()`/`imageAtEvent()` stay unchanged — the replace path for
    pages that already have images is untouched.
- **`Insert ▸ Image`** (`Sources/AnglesiteApp/InsertCommands.swift`):
  - Becomes a live `Button`, replacing the `PlannedItem("Image")` at
    `InsertCommands.swift:68`. Enabled when `SiteWindowModel.activeEditorFile`
    resolves (via `EditorKind`) to a page or component `.astro` file.
  - Action: `NSOpenPanel` restricted to image `UTType`s → read the picked
    file's bytes → build an `EditMessage` with `op: .insertImage`, the active
    file's project-relative path, **no `selector`** (so it lands at page/file
    root, matching the sidecar's no-selector fallback), and
    `value: {filename, mimeType, dataURL}` → send via `preview.editRouter`
    (the real `MCPApplyEditRouter`, already shared between the overlay and the
    Component Editor per `SiteWindowModel.makeComponentEditorContext`).
  - `.applied`: no further action needed — the dev server live-reloads the
    page.
  - `.failed`: `NSAlert`, same pattern `NewContentCommands.openSiteFromMenu()`
    already uses (`Sources/AnglesiteApp/FocusedSite.swift:88-100`).

## 5. Testing

- Sidecar: unit tests for the new dispatcher branch and insertion-point
  resolver (selector-anchored, no-selector fallback, no-match, non-image,
  malformed data URL) — mirroring `replace-image-src`'s existing test file.
- App: `EditMessage`/`ComponentStructureEditBuilder`-equivalent encode/decode
  round-trip for the new op constant; `InsertCommands` enablement logic
  (`EditorKind` gating); overlay Vitest coverage for the empty-page drop
  branch (`showTargets()` hint text, `drop` posting `insert-image` with no
  prior `src`).
- Manual: exercise both entry points against a freshly scaffolded site
  (`Resources/Template/src/pages/index.astro` ships with no `<img>` tags,
  per the issue) — this is also what unblocks #81's "Example photo" QA
  checklist row as a real end-to-end flow instead of a pre-seeded fixture.

## 6. Sequencing

1. Sidecar PR: schema + dispatcher + insertion resolver + tests. Ships in a
   tagged `anglesite-skills` release.
2. App PR: `EditMessage.Op` constant + overlay drop-insert branch + Insert ▸
   Image wiring, against the vendored tag. Closes #1408 and unblocks #81's
   checklist row.

## 7. Out of scope

- Inserting an Astro `<Image />` component (vs. a plain `<img>`) — the issue
  leaves this open; plain `<img>` matches what `replace-image-src` already
  produces, so this keeps the two ops consistent. A follow-up can add an
  `<Image />` variant once there's a concrete need.
- Multi-file / gallery insert (`Image Gallery` in the Insert menu stays a
  `PlannedItem`).
- Any change to the Component Editor's own drag-and-drop `insert-node` flow
  for the "img" palette entry, or to its attribute inspector — unaffected by
  this design.

## 8. Amendments (found while writing the plan)

1. **No `selector`-anchored variant for v1.** Both entry points always insert at the page's content root — dropping anywhere on an empty page behaves the same as `Insert ▸ Image`. *Reason: matching an arbitrary DOM container against raw `.astro` source turned out to be the highest-risk, most speculative part of the original design; the issue's own scope note treats selector-anchored insertion as an example, not a requirement.*

2. **Root-append means "inside the page's Layout wrapper," not literally the file's top-level nodes.** Every template page wraps its content in exactly one Layout component (e.g. `<BaseLayout>...</BaseLayout>` in `Resources/Template/src/pages/index.astro`) — appending at the literal AST fragment root would insert the `<img>` as a *sibling* of `<BaseLayout>`, outside the rendered page content entirely. The resolver descends one level into a sole wrapping component child before appending. *Reason: ensures the inserted image appears inside the rendered page layout instead of floating outside it as a sibling of the wrapper.*

3. **Pages only for v1, not component files.** `insert-image` addresses its target via a URL page path (`location.pathname` semantics, resolved through the existing `pathToAstroCandidates` helper), matching `replace-image-src`/`replace-text`'s existing shape — not a project-relative file path, which is what `src/components/*.astro` addressing would need. `Insert ▸ Image` is enabled whenever a page is loaded in the focused window's preview, not gated on `EditorKind`. *Reason: keeps the initial scope focused and reuses the established page-addressing pattern; component-file insertion can follow as a separate feature once the page case is stable.*
