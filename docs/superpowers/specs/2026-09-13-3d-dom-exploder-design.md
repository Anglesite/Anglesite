# 3D DOM exploder — exploded-layer view of the preview for debugging nested elements — design

**Date:** 2026-09-13
**Status:** draft
**Tracking:** [#1999](https://github.com/Anglesite/Anglesite/issues/1999)
**Related:** `JS/wysiwyg-engine/` (vision spec
[`2026-08-03-modern-wysiwyg-editor-design.md`](2026-08-03-modern-wysiwyg-editor-design.md) §3.1
"the engine owns no chrome"), the retired in-app Web Inspector
([`2026-06-23-web-inspector-design.md`](2026-06-23-web-inspector-design.md), removed in #1099),
the Debug Pane gate (`DebugPaneVisibility`, `Sources/AnglesiteApp/AnglesiteApp.swift`).

## 1. Summary

A debugging view for the preview `WKWebView` that renders the page's DOM as an
**exploded stack of translucent boxes**: every element becomes a box at its
on-page position, pushed back along Z by its nesting depth, and the whole stage
rotates under the pointer. Hovering a box names the element (tag, id/classes,
block id, size, depth, and the layout facts that usually explain a nesting
surprise: `position`, `overflow`, `display`, whether it starts a stacking
context); clicking selects the owning block in the editor. It is the spatial
answer to "which of these six wrappers is the one clipping my hero?" — the
question the flat 2D render can't answer and the in-app Web Inspector can no
longer be asked (#1099 removed it: WebKit offers no public API to open an
embedded inspector, and Safari's Develop menu means leaving the app).

Prior art: Firefox's 3D View ("Tilt", 2011–2019, WebGL) and the compositing
Layers tab in Safari's Web Inspector. Ours differs from the latter on purpose —
it shows **DOM nesting**, not compositor layers, because nesting is what a
theme author or an agent debugging a template actually reasons about.

It ships as plain CSS 3D transforms rendered by the existing dependency-free
`JS/wysiwyg-engine` bundle: no WebGL, no three.js, no private WebKit API, no
new dependency (CONTRIBUTING ▸ "Code guidelines").

## 2. Goals and non-goals

Goals:

- Make DOM nesting, clipping and stacking **visible at a glance** for any page
  the preview can load — edit mode on or off, local or remote runtime.
- Identify any box in one hover and jump from it to the editor's block
  selection in one click.
- Stay usable on a heavy page (node cap + subtree collapsing) and stay
  current while open (rebuild on DOM mutation / resize).
- Be testable with the engine's existing toolchain: vitest/jsdom for the
  layer model, Playwright for geometry and interaction.

Non-goals (v1):

- Rendering element *content* (textures, screenshots) on the boxes. Boxes are
  outlines with a depth tint; the dimmed live page underneath is the context.
- Editing from inside the exploded view. It is a debugging lens; edits stay
  in the block editor.
- Compositor-layer or paint-order visualization. That is Safari's Layers tab.
- Showing this to site owners by default. It is a debug-tier feature (§3).

## 3. Who it is for, and the gate

The audience is whoever is debugging a **template or theme**: the developer,
or an agent driving the app. The product direction of 2026-09-08 says the
owner never adjudicates technical details, so the exploder is gated exactly
like the Debug Pane: the View-menu item exists in Debug builds always, and in
Release only via the existing Settings opt-in ("Show Debug Pane menu item",
`AppSettings.debugPaneEnabled`) or ⌥ held at launch — the same
`DebugPaneVisibility.menuItemVisible(...)` predicate, evaluated once in
`AnglesiteApp.init()`. No new setting.

## 4. Architecture

```
JS/wysiwyg-engine/src/
├── dom-exploder/
│   ├── layer-model.ts    # pure: walk the DOM → LayerModel (depth, rect, summary, flags)
│   ├── tree-walk.ts      # pure: keyboard navigation over a LayerModel (parent/child/sibling)
│   └── stage.ts          # renderer: LayerModel → CSS 3D stage + HUD; pointer/keyboard handling
└── host/
    └── mount.ts          # + window.__anglesiteDomExploder = { open, close, toggle, isOpen }
```

- **`layer-model.ts` is renderer-independent.** It only reads the DOM
  (`getBoundingClientRect`, tag/attributes) and returns data. This is a
  deliberate seam: if the CSS-transform renderer misses its frame budget on a
  large page (§9), the swap to a `<canvas>` 2D projection is contained to
  `stage.ts`.
- **Separate entry from the engine.** The exploder does not require a mounted
  `WysiwygEngine`; it is defined by the same `WKUserScript` bundle (injected
  at `atDocumentEnd` by `WebViewBridge.localDevConfiguration`) but under its
  own `window.__anglesiteDomExploder` global, so it works with edit mode off.
  When the engine *is* mounted it uses it (§7) via the
  `window.__anglesiteWysiwygEngine` global `mount.ts` already declares.
- **Native side** (`Sources/`): a View-menu toggle, one `PreviewModel` method
  that calls into the global, and a small script-message handler that mirrors
  open/closed state back so the menu title flips (§8). No SwiftUI chrome of
  its own: the HUD is in-page, following `src/host/selection-toolbar.ts`'s
  precedent, which also keeps the feature portable to the Linux/iOS preview
  hosts (only the menu wiring is per platform).

## 5. Layer model

`buildLayerModel(root: Element, options): LayerModel`

Walks `root` (default `document.body`) breadth-first and produces a flat,
index-ordered array of nodes:

```ts
interface LayerNode {
  index: number;            // position in the flat array (stable within one build)
  parent: number | null;    // index of parent node, null for root
  depth: number;            // DOM ancestor count from root; root = 0
  rect: { x: number; y: number; width: number; height: number }; // document coords
  tag: string;              // lowercased
  id?: string;
  classes: string[];        // first 3, plus count
  blockId?: string;         // nearest data-anglesite-block-id ancestor (hit-test.ts's walk)
  collapsed: number;        // descendants folded into this node by the cap (0 = none)
}
interface LayerModel { nodes: LayerNode[]; root: Element; truncated: boolean; }
```

Rules:

- **Document coordinates**, not viewport: `getBoundingClientRect()` plus
  `scrollX/scrollY`, so the stage covers the whole page and the initial view
  fits the whole document (§7).
- **One read pass.** All rect reads happen before any DOM write; the stage is
  built afterwards. No interleaved reads/writes, so the build is one layout.
- **Skipped:** `head`, `script`, `style`, `template`, `noscript`; elements
  for which `Element.checkVisibility()` is `false` (`display: none`,
  `content-visibility: hidden`, and their descendants — without a
  `getComputedStyle` call); the app's own chrome (any element whose `id` starts with `__anglesite-`,
  which is what the engine's drag handle and toolbar already use, plus the
  exploder's own stage); and Astro's `<astro-dev-toolbar>` custom element,
  which is live in `astro dev` previews (the template does not disable it).
- **Zero-size elements are kept, not skipped.** A displayed element whose rect
  has zero area is very often the culprit this tool exists to find — an
  `overflow: hidden` wrapper collapsed by its own content, a zero-height
  accordion panel, a float container that never cleared. They stay in the
  model with their real (empty) rect and the renderer gives them a visible
  marker (§6). `checkVisibility()` is what makes this affordable: it
  answers the `display: none` question without a style read per node, so the
  rect no longer has to double as a visibility proxy. (jsdom implements
  neither it nor real geometry; the unit tests stub both, and the Playwright
  suite covers the real thing.)
- **Node cap** — 300 by default for the CSS-transform renderer, because
  WebKit promotes every 3D-transformed box to its own compositing layer and
  a few hundred layers is the realistic ceiling for a smooth rotate; 1,500
  is the cap the `<canvas>` renderer would carry if §9's measurement puts it
  on the table. 300 is plenty for the question this tool answers (the wrapper
  structure around one region), and re-rooting (§7) reaches anything deeper.
  Breadth-first order means the cap always keeps the shallow structure and
  drops the deepest leaves first. Each dropped
  subtree is counted onto its nearest kept ancestor's `collapsed`, which the
  renderer shows as a "+N" badge; double-clicking a collapsed box re-roots
  the exploder at that element (§7), which lifts the cap for that subtree.
- **Layout flags are lazy.** `position`, `overflow`, `display`, `z-index`,
  `transform`, `contain`, `isolation`, and the derived "starts a stacking
  context" are computed with `getComputedStyle` only for the hovered/focused
  node, never for all N up front. A HUD toggle "Highlight stacking contexts"
  runs that pass over the whole model on demand and tints matching boxes.

## 6. Rendering: the CSS 3D stage

One `<div id="__anglesite-dom-exploder">` appended to `document.documentElement`
(a sibling of `body`, not a child — so the mutation observer on `body` in §9
never sees the exploder's own writes):

```
#__anglesite-dom-exploder           position: fixed; inset: 0; z-index: 2147483647;
                                    perspective: 1800px;  pointer-events: auto
├── .scrim                          full-bleed, rgba(0,0,0,.55) — dims the live page beneath
├── .stage                          position: absolute; width/height = document scroll size;
│                                   transform-style: preserve-3d;
│                                   transform: translate(pan) scale(zoom) rotateX(rx) rotateY(ry)
│   └── .box × N                    position: absolute; left/top/width/height from rect;
│                                   transform: translateZ(depth × spacing)
└── .hud                            role="dialog"; the info panel + controls (§7)
```

- **Boxes are flat siblings of `.stage`, never nested.** Nesting is expressed
  only through Z. This is what makes `preserve-3d` hold: any intermediate
  element with `overflow`, `opacity`, `filter`, `clip-path` or a 2D-only
  `transform-style` flattens its subtree, so the stage's children must be
  the leaves.
- **Depth tint:** `hsl(depth × 25° mod 360, 70%, 55%)` at 0.18 alpha fill and
  0.8 alpha 1px border. Hover raises fill to 0.4 and draws the label. The
  selected block (when the engine is mounted) gets the same accent as the
  editor's selection handle so the two views agree.
- **Zero-size nodes** (§5) render as an 8×8 hollow diamond at the rect's
  origin, in the depth tint, so a collapsed wrapper is a visible thing on the
  stage rather than an invisible 0×0 box; its label says `0×0` and the HUD's
  clipping/stacking flags apply to it like any other node.
- **Spacing** (Z per depth level) defaults to 24px; `0` is "flatten", which
  is the plan view — the boxes collapse onto the dimmed page and become an
  ordinary outline overlay. That degenerate mode is a feature, not a
  fallback: it is the fastest way to see every box's true extent in 2D.
- **Motion:** opening animates spacing 0 → 24px over 200ms so the eye tracks
  which box came from where; `prefers-reduced-motion` disables the animation
  and every rotate/zoom transition.

## 7. Interaction

Pointer:

| Gesture | Effect |
|---|---|
| Drag | Rotate: horizontal → `rotateY`, vertical → `rotateX` (clamped ±80° so the stage never flips) |
| Scroll wheel / pinch | Zoom about the pointer |
| ⇧ + drag, or ⌥ + drag | Pan |
| Hover | Highlight box + label (tag#id.class, depth, size) |
| Click | Focus the box (HUD shows its full detail) and, if the engine is mounted, `engine.selection.select(blockId)` |
| Double-click | Re-root the exploder at that element (breadcrumb grows; ⌫ pops back) |

Keyboard (the HUD has focus while open; every action is reachable without
the pointer, per the Mac spec's keyboard requirement):

| Key | Effect |
|---|---|
| ← / → | Focus parent / first child |
| ↑ / ↓ | Focus previous / next sibling |
| ⏎ | Select the focused box's block in the editor |
| `[` / `]` | Decrease / increase spacing |
| `F` | Toggle flatten (spacing 0 ↔ last value) |
| `0` | Reset rotation, zoom and pan (fit whole document) |
| `D` / ⌫ | Re-root at focused / pop to previous root |
| ⌘C | Copy the focused element's path (`main > section:nth-child(2) > div.card`) — `formatElementPath()` from `layer-model.ts`, the one formatter the HUD breadcrumb, the clipboard copy and the pick log (§8) all share |
| Esc | Close |

HUD (top-right, in-page, mirrors `selection-toolbar.ts`'s hard-coded host
colors so it stays legible over any theme):

- Breadcrumb of the focused node's ancestors from the current root; each
  crumb is focusable and re-focuses that ancestor.
- Detail: tag, id, classes, block id (and the block's `componentName` from
  the engine's model when mounted), rect, depth, and the lazy layout flags
  from §5 — with "starts a stacking context" and "clips (`overflow` ≠
  `visible`)" spelled out in words, since those two are the usual culprits.
- Controls: spacing slider, depth-limit slider (hides boxes deeper than N —
  the quickest way to peel layers off), "Highlight stacking contexts" toggle,
  node count (`1,500 of 2,312 shown` when truncated), Done.

Selection is one-directional in v1: the exploder drives the engine's
selection through the existing `selection-changed` path (`mount.ts`
`wireSelection`), so the native inspector follows without any new native
wiring. Native-initiated selection changes are not reflected back into the
exploder until the next rebuild.

## 8. Native host wiring

- **Menu.** The Debug Pane `CommandGroup` in `AnglesiteApp.swift` (the one
  reading the private `debugPaneMenuVisible`) gains, under the same gate and
  directly below "Show Debug Pane", a toggle whose title flips between
  **Explode DOM** and **Collapse DOM**. Proposed shortcut ⌥⌘E — no `E`-based
  shortcut exists in the app today (checked against every
  `keyboardShortcut(` call in `Sources/AnglesiteApp/`); final choice is an
  open question (§13). Reaches the preview through the existing
  `\.preview` focused value (`PreviewNavigationCommands.swift`), and is
  disabled until `hasWebView`.
- **`PreviewModel.toggleDomExploder()`** evaluates
  `window.__anglesiteDomExploder?.toggle()` on the web view. The model keeps
  an `isDomExploderOpen` mirror, reset to `false` on every navigation
  (`didFinish`), because a reload discards the injected stage anyway.
- **JS → native.** A dedicated `WKScriptMessageHandler` namespace,
  `domExploder`, added to `WebViewBridge.localDevConfiguration` as a third
  optional `domExploderHandler:` parameter (defaulting to `nil`, like the
  existing two). `PreviewView` passes it **unconditionally** — not tied to
  edit mode the way `wysiwygHandler` is — so the exploder is available
  whenever the main preview is. The other two call sites,
  `ComponentEditorCanvasPane.swift` and `AnglesiteMobile/EditSiteScreen.swift`,
  keep passing only `handler:` and are deliberately out of v1: they get the
  inert JS global from the shared bundle but nothing native ever calls
  `toggle()` there, so no stage can appear. Extending the component editor
  is a one-line follow-up once the main preview has proven the view. Two
  messages:
  - `{ type: "state", open: boolean }` — keeps the menu title honest.
  - `{ type: "pick", summary: ElementSummary }` on ⏎/click — appended to the
    Debug Pane log as one line (`exploder: main > section:nth-child(2) >
    div.card (depth 4, 312×88, overflow:hidden)`), so a debugging session
    leaves a trail an agent can read back. The path is the same
    `formatElementPath()` string ⌘C copies (§7), computed in JS and sent
    as-is, so the two can't drift. Logs are sacred; this is the cheap way to
    make the exploder's findings durable.
  The handler is a ~40-line `DomExploderScriptHandler` in `AnglesiteBridge`
  with a decode test in `AnglesiteBridgeTests`, mirroring
  `WYSIWYGScriptHandler`.
- **Native → JS** is only `toggle()`/`close()`; nothing else crosses the
  bridge, which is the point of rendering in-page (§14 (a)).

## 9. Live updates and performance budget

- A `MutationObserver` on `document.body` (`childList`, `subtree`,
  `attributes`) plus a `ResizeObserver` on `documentElement` and `resize` /
  `scroll` listeners schedule a rebuild, debounced 250ms. Rebuilds reuse boxes
  by element identity (`WeakMap<Element, HTMLElement>`), updating rect/depth
  in place and creating/removing only the delta, so HMR churn does not
  re-create 1,500 boxes. Rebuilding pauses while `document.hidden`.
- **Budget:** build ≤ 50ms and a rotate frame ≤ 16ms at the 300-node default
  cap on the e2e fixture (§11) — that is the *common* case the CSS-transform
  renderer must meet, not a fallback trigger. The same fixture is also run at
  600 and 1,500 nodes to map where WebKit's one-compositing-layer-per-3D-box
  behavior falls over; those numbers decide whether the CSS cap can be raised
  and whether a single-`<canvas>` renderer with a manual projection is worth
  building to reach 1,500. If it is, it replaces `stage.ts`'s box DOM while
  `layer-model.ts` and `tree-walk.ts` stay untouched. Either way the decision
  is made from measurements, not up front.
- The exploder is inert until opened: nothing is observed, allocated or
  walked while it is closed, so the always-injected bundle costs the preview
  nothing.

## 10. Accessibility

- The stage is `aria-hidden`; VoiceOver users get the same information
  through the HUD, which is a `role="dialog"` with focus trapped while open,
  the breadcrumb and detail rendered as real text, and an `aria-live="polite"`
  region announcing the focused node on every tree-walk keystroke.
- Every pointer gesture in §7 has a keyboard equivalent; nothing is
  hover-only (the label shown on hover is the HUD's detail for the focused
  node).
- Colors carry no information that the HUD text does not repeat (depth is
  also a number; stacking-context tint is also a flag), so the depth hue ramp
  is free to be pretty.
- `prefers-reduced-motion` honored per §6.

## 11. Testing

Unit (vitest/jsdom, `JS/wysiwyg-engine/test/dom-exploder/`):

- `buildLayerModel`: depth and parent indices, document-coordinate rects
  (stubbed `getBoundingClientRect`), the skip list, `blockId` inheritance,
  breadth-first cap with `collapsed` counts and `truncated`.
- `tree-walk`: parent/child/sibling moves at every edge (root, leaf, last
  sibling), re-root and pop.
- Key mapping and HUD state (spacing, flatten memory, depth limit) as pure
  reducers.

Real browser (Playwright, `JS/wysiwyg-engine/e2e/dom-exploder.spec.ts`,
served by the existing `static-server.mjs`):

- Opening on `fixture.html` creates exactly one box per non-skipped element,
  positioned over its element's `boundingBox()`.
- Drag changes the stage's `rotateX`/`rotateY`; `0` resets; wheel zooms.
- Click on the box over block `b2` makes `window.__engine.selection.current`
  `"b2"`; Esc removes the stage and restores `body` untouched.
- Inserting a node after open produces a new box within the debounce.
- A generated 2,000-node fixture: the cap holds at 300, `truncated` is
  `true`, the deepest kept ancestor carries the `+N` badge, and the
  build/frame timings in §9 are asserted at 300 (with headroom for CI
  runners) and recorded, not asserted, at 600 and 1,500.
- A zero-size `overflow: hidden` wrapper in `fixture.html` gets a box marker,
  and a `display: none` subtree gets none.

Swift:

- `DomExploderScriptHandler` decode tests in `AnglesiteBridgeTests`.
- The menu gate reuses `DebugPaneVisibility`, which is already covered;
  the new item adds no predicate of its own.

## 12. Delivery

1. **This spec** (docs-only PR, tracked by #1999; does not close it).
2. **Engine PR:** `dom-exploder/` modules, the `__anglesiteDomExploder` global,
   unit + e2e tests. Pure JS; the bundle gains the entry but nothing native
   calls it yet, so it is inert in the app.
3. **Host PR:** View-menu toggle, `PreviewModel.toggleDomExploder()`,
   `domExploder` handler, Debug Pane log line. Closes #1999.

Two implementation PRs rather than one so the JS lands with its Playwright
coverage independent of the macOS lanes, matching how slices 2–3 of the
editor landed before slice 4 wired them into the app.

## 13. Open questions

- **Depth definition.** DOM depth is honest but wrapper-heavy themes produce
  runs of single-child `div`s that add levels without adding meaning. A
  "collapse pass-through wrappers" toggle (a node with one element child and
  the same rect) is cheap in the model; deferred until the plain view has
  been used on a few real themes.
- **Shortcut.** ⌥⌘E is proposed; confirm against the menu-bar spec's
  reservations before the host PR.
- **Pick logging.** Whether `pick` should also copy the CSS path to the
  clipboard automatically, or only on ⌘C as specified.

## 14. Alternatives considered

- **(a) Native SceneKit/RealityKit view** fed by harvested geometry (the
  deprecated overlay's `visible-elements.ts` already ships rects across the
  bridge). Rejected: every mutation would re-ship the whole model across the
  bridge, every hover would be a round trip, and the Linux/iOS preview hosts
  would get nothing. Apple-frameworks-only is satisfied just as well by
  vanilla JS in the existing engine.
- **(b) WebGL via three.js.** A new dependency needing approval, for no gain
  at a 1,500-node cap; CSS transforms already composite on the GPU.
- **(c) An Astro dev-toolbar app** in the template (`Resources/Template/`
  already registers custom integrations). Rejected: it would ship inside
  every owner's site and only exist under `astro dev`, not for a static or
  remote preview, and the app would not own its lifecycle or gate.
- **(d) Safari's Develop menu → Layers tab.** Shows compositor layers, not
  DOM nesting, and requires leaving the app. Still available via
  `isInspectable`; the exploder complements it.
- **(e) Reviving the in-app Web Inspector.** Private API only; dead since
  #1099 for every shipping build.
