# Image drop pipeline — optimize-on-drop with src + srcset patch

**Status:** approved — ready for implementation
**Note (2026-09-08, #1957):** the JS front half described here (`JS/edit-overlay`'s `attachImageDrop`) was retired with the click-to-edit overlay; the block editor's `JS/wysiwyg-engine/src/host/image-drop.ts` now drives the same `replace-image-src` sidecar pipeline through the `wysiwyg` bridge's `replace-image` message. The sidecar side is unchanged.
**Tracks:** [#32](https://github.com/Anglesite/Anglesite-app/issues/32) — Phase 9 step 3 of [build-plan.md](../build-plan.md#phase-9--v1-multi-site--drag-drop-images)
**Cross-repo:** paired PR against [Anglesite/anglesite](https://github.com/Anglesite/anglesite)
**Date:** 2026-05-26

## Motivation

Dropping an image onto an `<img>` in the WKWebView preview is the natural way for an owner to swap a photo — no file picker, no path-fiddling. The overlay's drop handler already exists (Phase 4 step 3) and posts an `apply-edit` with `op: "replace-image-src"`. The plumbing reaches `MCPApplyEditRouter`, hits the plugin's `apply_edit` MCP tool, and lands in `server/patcher.mjs` — where today's `replace-image-src` resolver is a stub that just sets the new `src=` to `value.filename` without saving the bytes or optimizing.

Phase 9 step 3 fills that gap. Drop → bytes saved → optimize → WebP + responsive variants → `<img>` patched (src + srcset). The optimize-images skill's existing `template/scripts/optimize-images.ts` runs sharp under the hood with EXIF stripping at fixed widths (480 / 768 / 1024 / 1920) and is the single source of truth for the optimize behavior.

## Behavior

Dropping a file onto an `<img>` in the preview:

1. **Overlay** (instant, no native round-trip): set `img.src = URL.createObjectURL(file)` so the new image renders immediately. Save the original `src` and `srcset` for revert. Post the `apply-edit` message with the file bytes as a data URL.
2. **Plugin patcher** (2–10 seconds): decode the data URL, write the bytes to `public/images/<basename>.<ext>`, move any pre-existing same-stem files into `public/images/originals/`, run the optimize function to produce `<basename>.webp` plus four width variants, build a `srcset` string covering all four widths, and patch the `<img>`'s `src` and `srcset` attributes in the source file via the existing range-replacement plumbing. Commit to the hidden `anglesite/edits` branch (existing Phase 5 #298 plumbing).
3. **Overlay** receives the `edit-applied` reply: swap `img.src` to the final WebP path, set `img.srcset` from the reply's metadata, revoke the blob URL.

On failure (sharp error, write failure, no matching `<img>` in source): plugin returns `edit-failed`. Overlay restores the saved original `src` / `srcset`, revokes the blob URL, and shows a small toast in the overlay with the failure detail.

## Naming

The dropped file inherits the target `<img>`'s current filename (without extension). Drop `vacation.jpg` on `<img src="/images/hero.jpg">` → bytes saved as `public/images/hero.jpg` (overwrite), optimize → `hero.webp` + variants, patch reads `<img src="/images/hero.webp" srcset="…">`.

**Fallback** when the target `src` is an external URL or otherwise unparseable: use the dropped file's original name as the basename. Collisions in this path are handled by the same overwrite-then-move-to-originals pattern as the inherit path.

**Why inherit:** matches the mental model of "I'm replacing this image, not adding a new one." Avoids orphan files cluttering `public/images/` over time. Combined with the existing Phase 5 hidden `anglesite/edits` git branch, the previous bytes are never lost — they live in the commit history plus `public/images/originals/`.

## Architecture

**Paired PR.** The crisp split:

| Repo | What changes |
|---|---|
| `anglesite` (plugin) | New `server/optimize-images.mjs` — the authoritative ES-module implementation of the optimize pipeline (sharp + EXIF strip + variants + originals/ preservation). New `server/patcher.mjs` `replace-image-src` resolver that imports from `server/optimize-images.mjs`. `template/scripts/optimize-images.ts` becomes a thin CLI wrapper that imports the server-side module and runs it against `public/images/` for the existing `npm run ai-optimize` entry point — the optimize-images skill's behavior is unchanged. New `image-optimize-failed` entry in `EDIT_FAILED_REASONS` (`server/messages.mjs`). |
| `Anglesite-app` | `JS/edit-overlay/src/overlay.ts` drop handler: optimistic blob URL + state save + swap-on-reply + revert-on-fail. Small toast component (CSS + a function in `overlay.ts`). No Swift changes — `MCPApplyEditRouter`, `EditMessage`, and the `replace-image-src` op are already wired and op-agnostic. |

The wire schema (`apply-edit-schema.mjs`) is unchanged. The overlay → bridge → MCP → plugin path is unchanged. Only the plugin's resolver and the overlay's drop-handler UX are new.

```
overlay.ts drop handler
  ├─ optimistic preview (set img.src to blob URL, save originals)
  ├─ post apply-edit { op: "replace-image-src", value: { filename, mimeType, dataURL } }
  ↓
WKWebView → AnglesiteScriptHandler → MCPApplyEditRouter
  ↓ (MCP apply_edit tool call)
plugin server/patcher.mjs replace-image-src resolver  ← NEW
  ├─ derive basename from target src (fallback: dropped name)
  ├─ decode dataURL → bytes
  ├─ move pre-existing public/images/<basename>.* to public/images/originals/
  ├─ write public/images/<basename>.<ext>
  ├─ optimizeImage(file, widths=[480,768,1024,1920])  ← imported from optimize-images.ts
  ├─ build srcset string from variants
  ├─ patch <img> src+srcset (range replacement covering both attrs)
  ├─ commit to anglesite/edits branch
  ↓ (edit-applied or edit-failed reply)
overlay.ts reply handler
  ├─ success: swap img.src + img.srcset to final values, revoke blob URL
  └─ failure: restore saved src/srcset, revoke blob URL, show toast
```

## Data flow — happy path

```
1. Owner drags vacation.jpg onto <img src="/images/hero.jpg" srcset="…">.
2. Overlay (zero wait):
     savedSrc = img.src; savedSrcset = img.srcset
     blobURL = URL.createObjectURL(file)
     img.src = blobURL; img.removeAttribute("srcset")
     postEdit({ op: "replace-image-src",
                value: { filename: "vacation.jpg", mimeType: "image/jpeg",
                         dataURL: "data:image/jpeg;base64,..." } })
3. Plugin patcher.replaceImageSrcResolver(message, projectRoot):
     a. Resolve <img> in source via existing patcher resolvers (uses
        selector.mjs.buildSelector + the same .mdoc / Keystatic / .astro
        cascade text edits already use).
     b. Parse current src attribute → basename "hero".
        If src is external (http*), use "vacation" (dropped name stem).
     c. Decode dataURL → Buffer.
     d. For each existing public/images/hero.* (including hero.webp, hero-480w.webp, etc):
          mv to public/images/originals/
        (existing optimize-images.ts already has this helper — reuse it)
     e. Write Buffer to public/images/hero.jpg.
     f. Call optimizeImage("public/images/hero.jpg",
                          { widths: [480, 768, 1024, 1920] })
        → returns { primary: "hero.webp",
                    variants: [{width: 480, file: "hero-480w.webp"}, …] }
     g. Build srcset:
          "/images/hero-480w.webp 480w, /images/hero-768w.webp 768w,
           /images/hero-1024w.webp 1024w, /images/hero-1920w.webp 1920w"
     h. Compute the source-file edit: replace the <img> tag's src= attribute
        with "/images/hero.webp" AND the srcset= attribute with the built
        string (single range replacement spanning both attrs).
     i. Apply the patch; commit to anglesite/edits.
4. Plugin emits edit-applied { id, file, range, commit }
     The reply carries metadata about the new src and srcset in either an
     extension field or via a per-op convention — see "Reply payload" below.
5. Overlay reply handler:
     img.src = "/images/hero.webp"
     img.srcset = "/images/hero-480w.webp 480w, …"
     URL.revokeObjectURL(blobURL)
```

### Reply payload

`edit-applied` today is `{ id, file, range, commit }`. The overlay needs the final `src` + `srcset` strings to apply on swap. Extend `edit-applied` with an optional `result` field: `createEditAppliedMessage(id, file, range, commit, result?)`. The wire format adds `result: { src: string, srcset?: string }`. The field is op-scoped — present for `replace-image-src`, absent otherwise. `result.srcset` is optional so future ops that only patch a single attribute don't need to fabricate one.

## Error handling

| Failure | Reason | Overlay response |
|---|---|---|
| No `<img>` found in source matching selector | existing `"no-match"` | Restore originals + toast |
| Selector matches multiple `<img>` tags | existing `"ambiguous"` | Restore originals + toast |
| sharp throws (corrupt image, format we don't support) | **new** `"image-optimize-failed"` | Restore originals + toast with sharp's error |
| Filesystem write fails | existing `"write-failed"` | Restore originals + toast |
| MCP roundtrip exceeds soft timeout (e.g. 30s) | new client-side timeout | Restore originals + toast "Optimize timed out — try a smaller image" |

New entry in `EDIT_FAILED_REASONS` (`server/messages.mjs`): `"image-optimize-failed"`. App-side `EditReply` decoder handles the new reason transparently (the existing JSONValue decode is permissive).

**Soft timeout:** overlay starts a 30-second timer on drop. If no reply lands by then, treat as failure. Without this, a hung MCP roundtrip leaves the optimistic preview in place forever.

## Testing

**Plugin-side (anglesite repo):**

- `test/patcher.test.js` gains `replace-image-src` cases:
  - Drop on an existing `<img>` with no srcset → patch contains the new `src` and an added `srcset` covering all four widths.
  - Drop on an `<img>` with existing srcset → srcset is rewritten with the new variant URLs.
  - Drop on an `<img>` with external src (`https://…`) → fallback to dropped filename's basename.
  - Existing `public/images/hero.jpg` and `hero.webp` → both moved to `originals/`.
  - sharp error → returns `{ refused: "image-optimize-failed", detail }`.
  - `no-match` / `ambiguous` / `write-failed` paths unchanged from existing text-edit tests.
- Use a tmpdir fixture with a small real JPEG (the existing test infra has image fixtures or can synthesize via sharp).
- `optimizeImage` is imported directly; tests run real sharp (it's fast enough that mocking buys nothing).

**App-side (Anglesite-app repo):**

- `JS/edit-overlay/test/overlay.drop.test.ts` (new or extends existing overlay tests):
  - Drop simulation sets `img.src` to a blob URL before the message posts.
  - Outgoing message shape: `op: "replace-image-src"`, `value.filename`, `value.mimeType`, `value.dataURL`.
  - Reply with `result: { src, srcset }` → `img.src` and `img.srcset` updated, blob URL revoked.
  - Reply with `edit-failed` → originals restored, blob URL revoked, toast visible.
  - 30s timeout → originals restored, toast visible.
- jsdom doesn't have a real `URL.createObjectURL` or `FileReader.readAsDataURL` — the existing overlay tests handle this with stubs; reuse the same pattern.

**No end-to-end test** runs sharp through the WKWebView. The smoke fixture (`scripts/create-smoke-fixture.sh`) gets a new manual step: "Drag an image onto a `<img>` in the preview, observe blob-URL preview + reply swap + new file in `public/images/`."

## Out of scope (deferred)

- **Multi-drop / batch.** Drop a single file at a time. Drop folder → first file wins, rest ignored.
- **Drop a new `<img>`.** Today's flow is replace-only (drop target must be an existing `<img>`). Inserting a new image element is a separate UI affordance.
- **Variant width customization.** The four widths (480/768/1024/1920) are hard-coded in `optimize-images.ts`. Owners who need different widths edit the script.
- **Progress events.** Single request/response is fine for the size range we expect (5–10 MB photos, sub-10s optimize). If optimize ever crosses 10s consistently we add MCP notification-style progress.
- **AVIF / JXL output.** WebP only for v1. AVIF is a follow-up once the optimize-images skill itself learns to emit AVIF.
- **Aspect-ratio enforcement.** If the new image has a different aspect ratio than the original, the `<img>` may render distorted. v1 doesn't intervene — owners deal with layout fallout in CSS.
