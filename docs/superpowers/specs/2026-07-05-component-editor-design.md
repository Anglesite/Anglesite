# Component Editor — Swift-native WYSIWYG for Astro components

**Date:** 2026-07-05
**Status:** Approved design, pre-implementation
**Related:** #459 (deterministic-path direction), #242 (package model), edit pipeline (`EditMessage` → MCP `apply_edit`), `docs/architecture.md` two-zone execution model
**Note (2026-09-08, #1957):** the click-to-edit overlay pages "kept" in the decision table was removed (decision D4); pages are edited by the block editor (`JS/wysiwyg-engine`), and the harness canvas module now lives at `JS/wysiwyg-engine/src/host/component-canvas.ts`, installed by the engine bundle's page bridge.

## 1. Summary

A native macOS Component Editor for `.astro` components: opening a component from the
navigator (today a plain `TextEditor` on a `.file` target) opens a three-pane editing
surface — structure outline + palette, rendered canvas, and a full inspector with a
Safari/Xcode-grade styles panel, props form, and zone-aware code editors.

Scope decisions (made during brainstorming):

| Decision | Choice |
|---|---|
| Product ceiling | **Compose-first, tiered** — assemble from existing components, extract-into-component, duplicate-and-modify; raw source always an escape hatch |
| Canvas | **Isolated harness only** — components edit in a dedicated per-component canvas; pages keep the existing click-to-edit overlay |
| Composition interaction | **Outline + canvas, both live** — hierarchy tree beside the render; insert/drag in either; selection synced |
| CSS inspector depth | **Full inspector panel** — authored rules, editable declarations, media queries, computed values |
| JS editor | **Zone-aware, both zones** — frontmatter TS ("Props & Data") and client `<script>` ("Behavior") as separate panes; whole-file Source tab as fallback |
| Component model ownership | **Plugin owns the model** — `@astrojs/compiler` in the container; semantic MCP ops; Swift tree-sitter is presentation-only |

The editor is fully deterministic Swift/TypeScript — no LLM in the loop — consistent
with the #459 direction. (Semantic ops are a natural future surface for FM tools /
App Intents, but that is out of scope here.)

## 2. Component model — plugin-owned, semantic ops

### 2.1 Ownership

The plugin gains a **component-model service** that parses `.astro` files with
`@astrojs/compiler` (already present in the container: it runs the Astro dev server).
This follows the `server/selector.mjs` precedent: source understanding lives in one
place, in the container, next to the patcher. The app never parses for semantics;
Swift-side tree-sitter exists only to highlight code panes.

Rejected alternatives:
- **Swift-owned model** (SwiftTreeSitter + tree-sitter-astro, text-patch ops): second
  parser that can drift from the real compiler; patch ops bypass semantic undo and
  server-side validation. The fork-prone path the codebase already rejected once.
- **Hybrid** (Swift reads, plugin writes): two parsers must agree about one file;
  every disagreement is a bug class.

### 2.2 Read tool

`get_component_model(path)` → JSON:

```jsonc
{
  "version": "<content hash of the file the model was computed from>",
                           // sha256 of the source, NOT a git SHA: apply_edit
                           // commits to the hidden edits branch without moving
                           // HEAD, so a repo SHA can't detect staleness (PR #410 review)
  "path": "src/components/Card.astro",
  "template": {            // tree of nodes
    "id": "n0",            // stable within this model version (index-path derived)
    "kind": "element",     // element | component | expression | slot | text
    "tag": "article",      // or component name for kind=component
    "attrs": [{ "name": "class", "value": "card", "span": [s, e] }],
    "span": [s, e],
    "children": [ /* … */ ]
  },
  "frontmatter": {
    "source": "…",
    "span": [s, e],
    "props": [ { "name": "title", "type": "string", "optional": false, "default": null } ]
  },
  "styles": [
    {
      "selector": ".card",
      "media": null,        // or the enclosing @media condition
      "span": [s, e],
      "declarations": [ { "property": "padding", "value": "1rem", "span": [s, e] } ]
    }
  ],
  "clientScript": { "source": "…", "span": [s, e] }   // or null
}
```

Node `id`s are index-path derived and stable **within one model version**; the app
refetches the model after every write, so ids never survive a mutation.

Expression nodes (`{items.map(...)}` etc.) are opaque single nodes: selectable,
inspectable, movable/removable as a unit — internals editable only via code panes.

### 2.3 Write ops

New `EditMessage.Op` values, routed through the existing `apply_edit` MCP tool.
Component ops carry a structured `component` payload (nodeId / rule key / zone,
plus `baseVersion`) where element edits carry `selector` today; the closed-set
strict decode extends to the new shapes on both sides. Each op returns
`{ commit, model }` (fresh model piggybacked to save a round-trip):

| Op | Payload | Effect |
|---|---|---|
| `insert-node` | parentId, index, node spec (element tag / component name / slot) | insert markup; auto-add component import to frontmatter if missing |
| `move-node` | nodeId, newParentId, newIndex | reorder/reparent |
| `remove-node` | nodeId | delete; prune now-unused imports |
| `set-attr` | nodeId, name, value \| null | set/remove attribute or component prop at the use-site |
| `set-style-property` | ruleIndex (or selector+media key), property, value | edit/add a declaration in the scoped `<style>` |
| `remove-style-property` | rule key, property | remove declaration |
| `add-style-rule` | selector, media?, declarations | append rule (creates `<style>` block if absent) |
| `set-rule-selector` | rule key, newSelector | rename selector |
| `set-script-zone` | zone: `frontmatter` \| `client`, source | replace a whole script zone (code-pane save) |
| `set-props-interface` | props array | codegen/update the `Props` interface in frontmatter |
| `extract-component` | nodeId, newName | new `.astro` file from the subtree, hoist obvious props, replace with instance + import |

**Concurrency:** if `baseVersion` ≠ the current file's content hash, the op is rejected with a
`stale` status; the app refetches and either replays trivially-mergeable ops or
surfaces the conflict banner (§5). This is the same optimistic pattern as the
existing external-change detection, moved server-side.

Every applied op is a git commit (existing pipeline), flows through
`MCPApplyEditRouter`, fires `onEdit` (chat-history record), and is undoable via the
existing commit-based `undo_edit` path.

**Paired-PR note:** ops + model service are plugin work shipped in a tagged plugin
release; the app bumps the bundled-plugin pointer per slice (§9).

## 3. Harness — the isolated canvas

A **dev-only Astro integration shipped in `Resources/Template/`** (app-owned; no
plugin PR needed) injects a route:

```
/_anglesite/component/<ComponentName>?props=<url-encoded JSON>
```

- Renders exactly one component. Prop values come from the query string; defaults
  derive from the `Props` interface. Unset non-optional props get type-based
  placeholders ("Sample title", `0`, `false`).
- Each `<slot>` is filled with visible sample content so components never render
  empty; named slots get labeled samples.
- The integration is a no-op in production builds (`command === 'dev'` guard), and
  `pre-deploy-check` continues to see no trace of it in output.

**Source mapping:** Astro dev mode annotates rendered elements with
`data-astro-source-file` / `data-astro-source-loc`. A new overlay module
(`JS/edit-overlay/src/component-canvas.ts`) uses these to map DOM ⇄ model spans:

- Canvas click → source loc → node id → outline selection (and reverse hover
  highlighting).
- Drop-target highlighting during palette/outline drags (valid insertion points
  derived from the hovered node).
- `getComputedStyle` report for the selected node → inspector's Computed section
  (same posting pattern as `visible-elements.ts`).

The canvas is the existing WKWebView + `AnglesiteScriptHandler` bridge with new
message types (`anglesite:canvas-selection`, `anglesite:computed-styles`), validated
with the same strict-decode discipline. Dev-server HMR repaints the canvas after each
committed write; no manual reload path.

A viewport-width control (device presets + free resize) on the canvas toolbar
supports responsive work and pairs with media-query editing in the styles panel.

## 4. UI composition

Replaces `MainPaneEditorView`'s plain-text path when the navigator `.file` target is
a component (`EditorKind.resolve()` grows a `.component` case). Three panes:

### 4.1 Left — Outline + Palette

- Hierarchy tree of `template` (Xcode view-hierarchy style). Selection synced with
  canvas both ways. Drag to reorder/reparent (`move-node`).
- **Component instances are sealed nodes**: children hidden (except slot-fill areas,
  shown as drop targets); props edited in the inspector; double-click opens that
  component's own editor (navigator push).
- **Expression nodes** show as a single "dynamic" chip — honest about what is not
  WYSIWYG-editable.
- Palette below the tree: project components (from `SiteFileTree`'s components
  group), a curated set of HTML elements (headings, text, image, link, list, section,
  div…), and `<slot>`. Drag into outline or onto canvas drop targets → `insert-node`.

### 4.2 Center — Canvas

Harness WKWebView, prop-knobs bar (controls generated from the `Props` interface:
text fields, toggles, steppers), viewport presets.

### 4.3 Right — Inspector (tabs)

- **Styles** — the full panel:
  - "Matched" section: rules whose selector matches the selected canvas node
    (match check runs in the canvas via `Element.matches()`), then all component
    rules.
  - Each declaration is an editable row: free-form text entry always available,
    plus type-appropriate native controls (ColorPicker for colors, box-model
    spacing widget for margin/padding, font controls, numeric steppers with unit
    menus).
  - Add declaration / add rule / edit selector / delete — all semantic ops.
  - Media queries as collapsible sections; "add media query" scaffolds a block.
  - **Computed** disclosure: read-only computed values from the canvas for the
    selected node.
  - All writes land in the component's scoped `<style>` — encapsulation by
    construction (matches the established project preference).
- **Attributes / Props** — attrs of the selected node (`set-attr`); when the
  component root is selected, the `Props` interface as a structured form
  (name / type / optional / default) driving `set-props-interface`, which also
  regenerates the harness knobs.
- **Code** — two STTextView panes: *Props & Data* (frontmatter TS) and *Behavior*
  (client `<script>`), tree-sitter highlighted, saved on ⌘S/blur via
  `set-script-zone`. A *Source* tab shows the whole file through the existing
  `FileEditorModel` path — the escape hatch, always available.

## 5. Edit lifecycle

- **Discrete gestures** (insert, move, attr/prop change, declaration commit): one
  semantic op → one git commit → model refetch (piggybacked) → HMR repaint.
- **Continuous scrubs** (dragging steppers/color picker): the app injects a temporary
  CSS override (`<style id="anglesite-scrub">` with an exact-node selector) directly
  into the WKWebView for 60 fps feedback; **one** `set-style-property` op fires on
  gesture end; the override is removed when HMR delivers the real change. No commit
  spam, no second parser.
- **Code panes**: dirty-tracked like `FileEditorModel`; explicit save.
- **Undo**: ⌘Z routes to the existing commit-based undo, then model refetch.

### Conflicts & errors

- **External edit** (user edits the file in VS Code): file-watch (existing
  `EditableFileSession` pattern) + server-side `baseVersion` check. Stale op →
  banner: "Changed outside Anglesite — Reload". Same UX as today's conflict flow.
- **Unparseable component** (compiler error): editor degrades to the Source tab with
  the compiler diagnostic in a banner. Never a dead end; fix in source, editor
  re-hydrates on save.
- **Harness render failure**: Astro's dev error overlay shows in the canvas;
  outline/inspector stay live from the last good model, structure ops disabled until
  the render recovers.
- Op failures surface via the existing `EditReply.failed` path into the debug pane —
  logs stay sacred.

## 6. Composability — how it's exposed

Three affordances on top of the palette:

1. **Nest** — drag a component from the palette into the tree; fill its slots via
   the slot drop-target areas of the sealed instance.
2. **Configure** — per-instance props in the inspector (`set-attr` at the use-site);
   the component's own interface via the Props form (definition-side).
3. **Create** — **Extract into Component…** on any outline selection: plugin op
   generates the new `.astro` file under `src/components/`, hoists obvious props
   (literal text/attr values referenced once), replaces the selection with an
   instance + import. Plus duplicate-and-modify from the navigator context menu.

Blank-canvas authoring falls out for free (New Component = template stub + this
editor) without being the designed-for path.

## 7. Dependencies (approved)

SPM, presentation-layer only — no host Node, no change to two-zone execution:

- [STTextView](https://github.com/krzyzanowskim/STTextView) — TextKit 2 code editing
  for the zone panes.
- [Neon](https://github.com/ChimeHQ/Neon) +
  [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) — highlighting.
- Grammar packages: tree-sitter-css, tree-sitter-javascript, tree-sitter-typescript;
  optionally [tree-sitter-astro](https://github.com/virchau13/tree-sitter-astro) for
  the Source tab (nested-language highlighting via SwiftTreeSitterLayer).

Surveyed and not chosen: CodeEditSourceEditor (README: not production-ready; larger
surface), Runestone (iOS-first — revisit for AnglesiteIOS), CodeEditorView (less
momentum).

## 8. Testing

- **Plugin**: vitest round-trip tests per op — parse → op → reparse invariants
  (idempotence, span integrity, import hygiene); fixture components covering slots,
  expressions, media queries, missing zones.
- **Swift**: model-decode fixtures; outline/inspector view-model logic in
  `AnglesiteCore` testable types (thin app layer, per the hosted-test CI
  constraint); Swift Testing.
- **E2E**: gated with `.enabled(if:)` on `ANGLESITE_PLUGIN_PATH` like
  `AppliesEditEndToEndTests` — open model, apply op, assert commit + reparse.
- **Overlay**: TS unit tests for `component-canvas.ts` (source-loc mapping,
  drop-target resolution), same harness as existing overlay tests.
- Template harness integration: template smoke test that the route renders a fixture
  component in dev and is absent from production builds. (Note: Swift tests couple
  to template markup — run `swift test` before pushing template changes.)

## 9. Phasing — vertical slices, each shippable

1. **Read-only editor**: `get_component_model` (plugin PR), harness route +
   `component-canvas.ts`, outline + canvas + selection sync, computed styles,
   Source tab. No writes.
2. **Styles panel**: style ops (plugin PR), declaration rows + native controls,
   scrub injection.
3. **Structure**: `insert-node` / `move-node` / `remove-node` / `set-attr`
   (plugin PR), palette, drag & drop, sealed instances.
4. **Props & code**: `set-props-interface` / `set-script-zone` (plugin PR), Props
   form, knobs bar, STTextView zone panes (dependency lands here).
5. **Extract & polish**: `extract-component` (plugin PR), duplicate-and-modify,
   media-query editing, viewport presets polish.

Slice 1 is the big plugin lift; each later slice's plugin ops ship as a tagged
plugin release with the app bumping the bundled-plugin pointer (standard paired-PR
flow).
