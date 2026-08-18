# Effects gallery — preset library + click-to-place (#768)

**Date:** 2026-08-17
**Status:** Approved (brainstorm 2026-08-17)
**Repos:** `Anglesite/Anglesite-app` only — no sidecar (`Anglesite/anglesite-skills`) changes required

## Context

The `creative-canvas` skill (open-ended Three.js/P5 code-gen) is retired per the Claude Code
removal roadmap's Bucket 6 (`docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md`
§5). The roadmap leaves an optional Bucket 3 replacement: a small, vetted library of preset
visual effects the owner picks from a gallery, deterministically wired into the site — no
code-gen. The owner (2026-08-15) confirmed a replacement is wanted (issue #768 comment).

Two precedents already exist and made opposite choices about "does the app place the
component for the owner":

- **`IntegrationCatalog`/`IntegrationWizard`** (`Sources/AnglesiteCore/IntegrationCatalog.swift`,
  `Sources/AnglesiteApp/IntegrationWizard.swift`) — Swift-literal descriptors, full
  pick→configure→apply wizard, deterministic file copy + anchor injection via
  `IntegrationScaffolder`.
- **`AnimationCatalog`/`AnimationsGalleryView`** (`docs/superpowers/specs/2026-07-27-astro-animate-design.md`)
  — JSON manifest of 16 curated CSS micro-animations, each with a prerendered static demo
  shown in a sandboxed `WKWebView`. Explicitly browse + copy-snippet only: *"No deterministic
  'insert component into page X at position Y' machinery — placement stays conversational."*

Issue #768 asks for the deterministic-placement behavior ("the app wires into a page
component"), closer to `IntegrationWizard`. Brainstorm decisions (2026-08-17) expanded scope:
merge the two galleries into one unified **Effects** system, add real click-to-place, and
build out a preset library across four new visual-effect styles rather than just cleaning up
the retirement.

The click-to-place mechanism turned out to be lower-risk than initially assessed: the
sidecar's `get_page_model` MCP tool and the `insertBlock`/`moveBlock`/`deleteBlock`/`setProp`
ops (with `blocks.manifest.json`-based name resolution) are **already merged on
`anglesite-skills`'s `main` branch** (issue #1222's sidecar half shipped; only app-side
consumption is outstanding). `blocks.manifest.json` is a plain project-root data file the
sidecar reads — not sidecar code — so registering effects in it is app-owned template work.
This means the full click-to-place scope ships as an **app-only PR**, no paired sidecar PR,
and incidentally unblocks part of the WYSIWYG page-editor epic's (#1221) own consumption of
the same tools.

## Goals

- One unified **Effects** gallery replacing today's Animations gallery, covering both the
  existing 16 CSS micro-interactions and 12 new "bigger" visual effects (creative-canvas's
  intended replacement).
- Deterministic placement: pick an effect, click where it goes in the live preview, the app
  wires it in — no copy-paste required (though copy-paste remains available).
- No third-party JS libraries (ADR-0008) — every new effect is vanilla Canvas 2D / DOM APIs /
  CSS, authored in-house.
- Reuse existing, proven infrastructure wherever it exists (`get_page_model`, `insertBlock`,
  the Component Editor's MCP round-trip pattern) rather than building parallel machinery.

## Non-goals

- No open-ended effect generation — the library is fixed and curated, matching Bucket 3's
  "no model needed" framing.
- No arbitrary-shape placement (`wrapper`/reparent-on-insert) in v1 — only `inline`
  (before/after a clicked element) and `background` (behind/first-child of a clicked
  element's parent) placement kinds ship. A wrapper kind would need a `moveBlock` reparent on
  top of insert and no effect in the v1 list needs it.
- No changes to the sidecar (`Anglesite/anglesite-skills`) — confirmed unnecessary; see
  Context.
- Not fixing the pre-existing possible CSP gap in `BookingWidget.astro`'s inline Cal.com/
  Calendly loader scripts (flagged separately, out of scope here). New effects avoid the same
  mistake by using bundled (non-`is:inline`) `<script>` tags.

## Architecture

### 1. Catalog data model (`AnglesiteCore`, template)

`AnimationCatalog` → renamed `EffectCatalog`, decoding a renamed manifest
`Resources/Template/integrations/effects.json` (was `animations.json`). Entry shape grows by
one field:

```ts
{
  component: string,          // e.g. "ParticleField"
  title: string,
  ownerDescription: string,
  category: EffectCategory,   // existing 5 + 4 new (below)
  keyProps: Record<string, string>,
  snippet: string,            // import + usage, for manual copy-paste
  placement: {
    kind: "inline" | "background",
    allowedParents: string[] | null,  // tag allowlist for the insertion target, null = any
  },
}
```

- `EffectCategory` grows from `text | cards | buttons | backgrounds | navigation` (unchanged,
  existing 16 entries keep their category) to add `canvasBackground | cursorReactive |
  scrollDriven | generativeArt`.
- Demo files move `integrations/animations-demos/` → `integrations/effects-demos/<component>.html`
  (same self-contained-static-HTML convention, migrated wholesale for the 16 existing
  entries — a template test enforces the rename is complete, no stray old paths).
- `placement` is only consulted by the click-to-place flow (§3); manual copy-paste is
  unaffected and needs no placement metadata to keep working.

### 2. Placeable-block registration (`blocks.manifest.json`, template)

A new project-root file, read by the sidecar's existing `loadBlockManifest`
(`server/block-manifest.mjs`) — schema `anglesite-block-manifest/1`. One entry per effect
component:

```json
{
  "path": "src/components/ParticleField.astro",
  "export": "ParticleField",
  "kind": "astro",
  "name": "Particle Field",
  "description": "Drifting dots connected by faint lines when close",
  "propEditors": [],
  "slots": [],
  "placement": { "allowedParents": null }
}
```

- Shipped pre-populated for new sites (part of the template scaffold).
- For **existing** sites created before this feature: `EffectCatalog` load triggers a sync
  step — if `blocks.manifest.json` is missing, create it with all shipped effects; if
  present, append any `modules` entries missing by `path`, and never touch entries it didn't
  write (same "never clobber, warn and skip" rule `IntegrationScaffolder` already follows for
  owner-editable files). This runs as a light check on gallery open, not a background
  scanner — no new file-watching infrastructure.

### 3. Click-to-place mechanism

New Swift types/clients, modeled directly on the Component Editor's existing MCP round trip
(`ComponentModelClient` → `ComponentStructureEditBuilder` → `MCPApplyEditRouter`) — **not**
the in-progress WYSIWYG epic's `BlockModel`/`WYSIWYGHostTransport` machinery, which is a
different wire protocol (host↔JS-engine ops) and is intentionally left alone mid-epic,
blocked on #1222's app-side slice.

- **`PageModelClient`** (new, `AnglesiteCore`, same shape as `ComponentModelClient`):
  `getPageModel(path:) async -> Result<PageModel, ModelError>` calling the sidecar's
  `get_page_model` tool (already registered, zero sidecar work). `PageModel`/`PageModelNode`
  Codable types mirror the sidecar's tree: `id, kind, tag, attrs, span, children, block?`.
- **`EditMessage.Op.insertBlock`** (new string constant, `AnglesiteCore/EditMessage.swift`)
  and **`ComponentStructureEditBuilder.insertBlock(id:path:baseVersion:parentId:index:manifestBlock:)`**
  (new sibling to the existing `insertNode` builder) — emits the `component:` payload shape
  the sidecar's `insertBlock` op already accepts (`parentId`, `index`, `manifestBlock`).
- **Overlay placement-pick mode** (`JS/edit-overlay`): entered only via an explicit Swift→JS
  call (`window.anglesite._enterPlacementMode()` / `_exitPlacementMode()`), never
  ambient. While active, every element (not just `EDITABLE_TAG`) becomes click-targetable;
  hover shows an insertion-point affordance; click posts a new message type
  `anglesite:pick-placement` (distinct from `anglesite:apply-edit`) carrying the same
  `elementInfoFor()` payload the existing click-to-edit path already produces. Outside
  placement mode, today's text-edit click behavior is unchanged.
- **Client-side match** (Swift): on receiving a placement click, fetch
  `getPageModel(path:)` for the current route, walk the tree matching
  tag/id/classes/nthChild/ancestor-chain (mirroring `selector.mjs`'s own ancestor-walk
  priority: `data-anglesite-id` → `data-testid` → `#id` → `role`/`aria-label` →
  `tag.stableClasses` → `tag:nth-child(n)`) to resolve the clicked `ElementInfo` to a node id,
  then its `parentId` + sibling index. `entry.placement.kind` decides the actual insertion
  index: `inline` → before/after the matched node (owner's choice via a small before/after
  toggle in the placement HUD); `background` → first child of the matched node's *parent*
  (i.e., placed behind it, not adjacent).
- **Apply**: build the `insertBlock` `EditMessage` with the resolved `parentId`/index +
  `manifestBlock` name + the fetched model's `version` as `baseVersion`, route through the
  existing `MCPApplyEditRouter.apply(_:)`, reconcile the reply, refresh preview. If the
  sidecar doesn't advertise `insertBlock` (old cached tool list), `MCPClient.callTool`'s
  existing `apply_edit`-op guard throws `MCPError.unsupportedOp` — surfaced as a normal error,
  no special-casing needed.

### 4. Gallery UI & App Intent

- `AnimationsGalleryView` → `EffectsGalleryView` (mechanical rename), one menu-command text
  update (`WebsiteCommands.swift`: "Animations…" → "Effects…"). Sidebar keeps the existing
  `NavigationSplitView` + category grouping, now under two section headers —
  **Micro-interactions** (5 existing categories) and **Visual effects** (4 new) — so the
  doubled entry count (16 + 12 = 28) stays scannable.
- Detail pane unchanged (description, key-props table, live demo `WKWebView`) plus a new
  **"Apply to page…"** button. Clicking it starts placement-pick mode (§3) on the active site
  window's live preview: a small HUD reads "Click where to place this effect" with
  before/after toggle (for `inline` effects) and Cancel (button + Esc). On click, match/apply
  runs and the HUD shows success/failure inline before dismissing. "Copy Snippet" stays as
  the manual fallback for owners editing outside the app or wanting a different spot than a
  click can reach.
- **`AddEffectIntent`** (new, `Sources/AnglesiteIntents/EffectIntents.swift`), modeled on
  `AddStoreIntent`'s router pattern: `@Parameter` effect choice (`AppEnum` generated from the
  catalog's stable `component` ids) + target route. No live-preview click available from
  Siri, so placement defaults per `placement.kind` (`background` → end of `<body>`; `inline`
  → first element matching `allowedParents`, or page root if unconstrained). Plans before
  confirming so a missing/ambiguous placement reprompts rather than false-confirming, same as
  `AddStoreIntent`.

### 5. Preset effect library (12 new components)

All vanilla Canvas 2D / DOM / CSS — no third-party JS (ADR-0008-clean, the mistake the
retired `creative-canvas` skill's Three.js/P5 code-gen made). Every effect respects
`prefers-reduced-motion` (freezes to a static frame) and is gated by `IntersectionObserver`
so off-screen instances don't run. Any effect needing real script logic uses a plain
(non-`is:inline`) Astro `<script>` — Astro bundles these into hashed same-origin
`/_astro/*.js` files, satisfying the template's `script-src 'self'` CSP baseline with no CSP
changes and no CSP violation (unlike `BookingWidget.astro`'s pre-existing `is:inline` inline
script bodies — see Non-goals).

| Category | Placement | Components |
| --- | --- | --- |
| `canvasBackground` | `background` | Particle Field (drifting dots, faint connecting lines when close), Aurora Gradient (slow blurred color-blob blending), Grain Overlay (subtle animated film-grain texture) |
| `cursorReactive` | `inline` | Magnetic Button (eases toward cursor within a radius), Cursor Glow (soft trailing glow blob), Tilt Card (3D perspective tilt following pointer) |
| `scrollDriven` | `inline` | Parallax Layers (differential-speed background layers), Reveal Mask (`IntersectionObserver`-driven clip-path reveal), Scroll Progress Trace (canvas-drawn line that traces in as the page scrolls) |
| `generativeArt` | `inline` | Blob Morph (CSS `clip-path` keyframe animation, no JS), Mesh Gradient (drifting multi-stop SVG radial gradients, no JS), Dot Grid Pulse (staggered-opacity dot grid, no JS) |

## Testing

- **Swift (`AnglesiteCoreTests`):** `EffectCatalog` decode/validation (including the merged
  9-category set); `PageModelClient`/`ComponentStructureEditBuilder.insertBlock` round-trip
  against stubbed sidecar responses (mirroring existing `ComponentModelClient` tests); the
  `ElementInfo`→node placement-matching algorithm against fixture `PageModel` trees — this is
  the highest-value new test surface since it's genuinely new logic, not a reuse of an
  existing pattern.
- **JS overlay (`JS/edit-overlay`, vitest):** placement-pick mode click reporting;
  confirm `EDITABLE_TAG` gating is unaffected outside placement mode.
- **Template (`npm test` in `Resources/Template/`):** each of the 12 new components gets the
  same harness-smoke-test coverage the 16 existing animations have (marker attribute,
  reduced-motion CSS); a consistency test asserts every `effects.json` entry has a matching
  demo file and (for placeable ones) a `blocks.manifest.json` entry with a matching `path`.
  `pre-deploy-check.ts`/CSP tests confirm no new component emits a literal inline `<script>`
  body.
- **e2e (`ANGLESITE_PLUGIN_PATH` gated):** an `insertBlock` round trip through the real
  sidecar, alongside existing `AppliesEditEndToEndTests`/`MCPClientHTTPEndToEndTests` — the
  first real exercise of `insertBlock` from the app side.
- **Migration:** a test scaffolds a pre-feature site fixture (no `blocks.manifest.json`),
  loads `EffectCatalog`, and asserts the sync step creates/merges it without touching
  unrelated existing content.

## Risks

| Risk | Mitigation |
| --- | --- |
| Placement-matching (tag/id/class/nthChild/ancestor-chain) picks the wrong node on a page with unusual structure | Mirrors `selector.mjs`'s existing, already-proven ancestor-walk priority; HUD shows a highlight on the matched target before committing (confirm-before-apply), not blind insert-on-click |
| `blocks.manifest.json` sync silently diverges from what's actually on disk (owner deleted a component file but the manifest entry lingers) | `insertBlock`'s existing sidecar-side resolution already errors on a manifest entry whose `path` doesn't resolve (`no-match`) — surfaced as a normal apply failure, not a crash |
| 28-entry gallery is harder to scan than today's 16 | Two-section grouping (Micro-interactions / Visual effects); category filter already exists in the sidebar |
| Canvas/cursor effects hurt Core Web Vitals or battery if not gated | `IntersectionObserver` gate + `prefers-reduced-motion` freeze on every effect, enforced by the template smoke test |
| `wrapper` placement gets requested later and doesn't fit the v1 model | Explicit non-goal; `moveBlock` (already shipped sidecar-side) is the natural extension point when needed |

## Rollout / process

1. Claim #768 (`🛠️ In Progress` label).
2. Single PR (per owner decision 2026-08-17 — full end-to-end scope, not sliced): catalog
   unification + `blocks.manifest.json` + `PageModelClient` + `insertBlock` builder +
   overlay placement mode + gallery UI/rename + App Intent + all 12 new components + tests.
3. No paired sidecar PR — confirmed unnecessary (Context).
4. Follow-up (separate, already flagged): audit `BookingWidget.astro`'s inline-script CSP
   compliance — unrelated pre-existing gap surfaced during this design's research.
