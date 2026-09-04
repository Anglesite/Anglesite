# Effects Gallery Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the retired `creative-canvas` skill with a unified Effects gallery — merges the existing 16-entry `AnimationCatalog` with 12 new hand-authored visual effects, adds deterministic click-to-place (pick an effect, click where it goes in the live preview), and ships entirely app-side on top of the sidecar's already-merged `get_page_model`/`insertBlock` tools.

**Architecture:** `EffectCatalog` (renamed/extended `AnimationCatalog`) drives a two-section gallery (Micro-interactions / Visual effects). A new `PageModelClient` fetches the current page's node tree; a new `PlacementMatcher` resolves a live-preview click's `ElementInfo` to a node id in that tree; `ComponentStructureEditBuilder.insertBlock` + the existing `MCPApplyEditRouter` apply the edit via the sidecar's `insertBlock` op, resolving the effect by name via a new `blocks.manifest.json`. Only the 12 new effects are placeable (they have real `src/components/effects/*.astro` files in every site); the 16 legacy `@astroanimate/core`-backed entries stay copy-paste-only, matching their existing library-import nature.

**Tech Stack:** Swift 6.4/SwiftUI (`AnglesiteCore`, `AnglesiteApp`, `AnglesiteIntents`, `AnglesiteBridge`/`AnglesiteBridgeCore`), TypeScript/vitest (`JS/edit-overlay`), Astro/TypeScript/vitest (`Resources/Template`). No sidecar changes.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-17-effects-gallery-design.md` — read it before starting; every task below implements a piece of it.
- No third-party JS libraries in new effect components (ADR-0008) — vanilla Canvas 2D / DOM / CSS only.
- New effects needing script logic use plain (non-`is:inline`) Astro `<script>` tags, never `is:inline` with a literal inline body (CSP: `script-src 'self'`, no `unsafe-inline`, no hashes).
- Every effect with motion respects `prefers-reduced-motion` and is gated by `IntersectionObserver` (no off-screen rAF loops).
- Single PR per owner decision (2026-08-17) — but land it as the ordered commits below; each task's own commit is a reviewable checkpoint even though they ship together.
- Follow `CONTRIBUTING.md`: conventional commits referencing #768, subject ≤72 chars.
- Run `swift test --package-path .` and (from `Resources/Template/`) `npm test` and (from `JS/edit-overlay/`) `npm run lint && npm run typecheck && npm test` before considering the plan done.

---

### Task 1: `EffectCatalog` — rename and extend `AnimationCatalog`

**Files:**
- Modify → Create: `Sources/AnglesiteCore/AnimationCatalog.swift` → `Sources/AnglesiteCore/EffectCatalog.swift` (git mv + edit)
- Modify → Create: `Tests/AnglesiteCoreTests/AnimationCatalogTests.swift` → `Tests/AnglesiteCoreTests/EffectCatalogTests.swift`

**Interfaces:**
- Produces: `public struct EffectCatalogEntry: Sendable, Codable, Identifiable, Hashable` with fields `component, title, ownerDescription, category: EffectCategory, keyProps: [String: String], snippet: String, placement: Placement?`; `public struct Placement: Sendable, Codable, Hashable { public let kind: Kind; public let allowedParents: [String]?; public enum Kind: String, Sendable, Codable, Hashable { case inline, background } }`; `public enum EffectCategory: String, Sendable, Codable, CaseIterable, Hashable { case text, cards, buttons, backgrounds, navigation, canvasBackground, cursorReactive, scrollDriven, generativeArt }`; `public struct EffectCatalog: Sendable { public let entries: [EffectCatalogEntry]; public static func load(templateDirectory: URL) throws -> EffectCatalog; public func entries(in category: EffectCategory) -> [EffectCatalogEntry]; public static func demoURL(templateDirectory: URL, component: String) -> URL }`.
- Consumes: nothing new (pure decode of `integrations/effects.json`, produced by Task 2).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/EffectCatalogTests.swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite struct EffectCatalogTests {
    @Test func loadsRealTemplateCatalog() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        #expect(!catalog.entries.isEmpty)
        for entry in catalog.entries {
            let demo = EffectCatalog.demoURL(templateDirectory: try templateRoot(), component: entry.component)
            #expect(FileManager.default.fileExists(atPath: demo.path), "\(entry.component)")
        }
    }

    @Test func groupsByCategory() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        let grouped = EffectCategory.allCases.flatMap { catalog.entries(in: $0) }
        #expect(grouped.count == catalog.entries.count)
    }

    @Test func onlyNewCategoriesArePlaceable() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        let legacy: Set<EffectCategory> = [.text, .cards, .buttons, .backgrounds, .navigation]
        for entry in catalog.entries {
            if legacy.contains(entry.category) {
                #expect(entry.placement == nil, "\(entry.component) is a legacy micro-animation, should not be placeable")
            } else {
                #expect(entry.placement != nil, "\(entry.component) is a new effect, must declare placement")
            }
        }
    }

    @Test func decodesFromFixtureJSON() throws {
        let json = """
        {"version":2,"components":[
          {"component":"FadeInText","title":"Fade-in text","ownerDescription":"d","category":"text","keyProps":{},"snippet":"s"},
          {"component":"ParticleField","title":"Particle Field","ownerDescription":"d","category":"canvasBackground","keyProps":{},"snippet":"s","placement":{"kind":"background","allowedParents":null}}
        ]}
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("integrations"), withIntermediateDirectories: true)
        try json.write(to: tmp.appendingPathComponent("integrations/effects.json"), atomically: true, encoding: .utf8)
        let catalog = try EffectCatalog.load(templateDirectory: tmp)
        #expect(catalog.entries.count == 2)
        #expect(catalog.entries[0].placement == nil)
        #expect(catalog.entries[1].placement?.kind == .background)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter EffectCatalogTests`
Expected: FAIL — `EffectCatalog`/`EffectCatalogEntry`/`EffectCategory` don't exist yet.

- [ ] **Step 3: Rename and extend the implementation**

```bash
git mv Sources/AnglesiteCore/AnimationCatalog.swift Sources/AnglesiteCore/EffectCatalog.swift
```

Replace its contents:

```swift
// Sources/AnglesiteCore/EffectCatalog.swift
import Foundation

/// One curated entry from the template's `integrations/effects.json` manifest — either a legacy
/// `@astroanimate/core` micro-animation (no `placement`, copy-paste only) or a hand-authored
/// visual effect with a real `src/components/effects/*.astro` file in every site (`placement`
/// non-nil, placeable via the click-to-place flow). Foundation-only: the Linux CI lane builds
/// AnglesiteCore, so no AppKit/Darwin-only APIs belong here — the AppKit-facing gallery UI lives
/// in `Sources/AnglesiteApp/EffectsGalleryView.swift`.
public struct EffectCatalogEntry: Sendable, Codable, Identifiable, Hashable {
    /// `Identifiable` conformance for SwiftUI lists — the component export name, which the
    /// manifest keeps unique, so no separate id field is needed.
    public var id: String { component }
    /// The component's export/tag name (e.g. `FadeInText`, `ParticleField`) — the stable key
    /// everything else (demo pages, snippets, blocks.manifest lookups) derives from.
    public let component: String
    /// Short human title shown in the gallery grid.
    public let title: String
    /// Plain-language description written for site owners, not developers.
    public let ownerDescription: String
    /// Which gallery section the entry belongs to.
    public let category: EffectCategory
    /// The props worth tuning, mapped to a human hint about each — display strings for the
    /// gallery, not machine-readable defaults.
    public let keyProps: [String: String]
    /// Ready-to-paste Astro usage snippet, import line included.
    public let snippet: String
    /// How this effect gets deterministically inserted, or `nil` for a legacy library-backed
    /// micro-animation with no local component file to place.
    public let placement: Placement?

    public init(component: String, title: String, ownerDescription: String, category: EffectCategory, keyProps: [String: String], snippet: String, placement: Placement? = nil) {
        self.component = component
        self.title = title
        self.ownerDescription = ownerDescription
        self.category = category
        self.keyProps = keyProps
        self.snippet = snippet
        self.placement = placement
    }

    /// Insertion behavior for a placeable effect.
    public struct Placement: Sendable, Codable, Hashable {
        public let kind: Kind
        /// Tag allowlist for the click-to-place target's parent; `nil` means any element.
        public let allowedParents: [String]?

        public init(kind: Kind, allowedParents: [String]?) {
            self.kind = kind
            self.allowedParents = allowedParents
        }

        /// `inline`: insert before/after the clicked element. `background`: insert as the first
        /// child of the clicked element's *parent*, behind it.
        public enum Kind: String, Sendable, Codable, Hashable {
            case inline
            case background
        }
    }
}

/// `category` values from the manifest schema. The first five are legacy `@astroanimate/core`
/// micro-animations (unchanged from the original `AnimationCategory`); the last four are the new
/// hand-authored visual effects (#768).
public enum EffectCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case text
    case cards
    case buttons
    case backgrounds
    case navigation
    case canvasBackground
    case cursorReactive
    case scrollDriven
    case generativeArt
}

/// Decodes the template's curated Effects catalog and locates its prerendered demo pages.
public struct EffectCatalog: Sendable {
    /// Every curated entry, preserving manifest order — the template's curation order *is* the
    /// gallery's display order, so no re-sorting happens app-side.
    public let entries: [EffectCatalogEntry]

    /// Mirrors the manifest's top-level shape (`{ "version": 2, "components": [...] }`); only
    /// `components` is consumed today.
    private struct ManifestFile: Codable {
        let version: Int
        let components: [EffectCatalogEntry]
    }

    /// Decodes `templateDirectory/integrations/effects.json`.
    public static func load(templateDirectory: URL) throws -> EffectCatalog {
        let manifestURL = templateDirectory.appendingPathComponent("integrations/effects.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ManifestFile.self, from: data)
        return EffectCatalog(entries: manifest.components)
    }

    /// Curated entries in `category`, in manifest order.
    public func entries(in category: EffectCategory) -> [EffectCatalogEntry] {
        entries.filter { $0.category == category }
    }

    /// The prerendered demo page for `component`: `integrations/effects-demos/<component>.html`
    /// under the same template root.
    public static func demoURL(templateDirectory: URL, component: String) -> URL {
        templateDirectory.appendingPathComponent("integrations/effects-demos/\(component).html")
    }
}
```

```bash
git mv Tests/AnglesiteCoreTests/AnimationCatalogTests.swift Tests/AnglesiteCoreTests/EffectCatalogTests.swift
```
(overwrite with the Step 1 content above)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter EffectCatalogTests`
Expected: `loadsRealTemplateCatalog`/`groupsByCategory`/`onlyNewCategoriesArePlaceable` FAIL until Task 2 renames the template manifest — that's expected at this point; `decodesFromFixtureJSON` (the fixture-only test) should PASS now. Re-run the full suite after Task 2 and confirm all four pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/EffectCatalog.swift Tests/AnglesiteCoreTests/EffectCatalogTests.swift
git commit -m "feat(#768): rename AnimationCatalog to EffectCatalog, add placement"
```

---

### Task 2: Rename the template manifest, migrate 16 legacy entries

**Files:**
- Modify: `Resources/Template/integrations/animations.json` → `Resources/Template/integrations/effects.json` (git mv, add `"version": 2`, no `placement` key on any entry)
- Modify: `Resources/Template/integrations/animations-demos/` → `Resources/Template/integrations/effects-demos/` (git mv, directory of 16 `.html` files, unchanged content)
- Modify: `Resources/Template/integrations/docs/animations.md` → `Resources/Template/integrations/docs/effects.md` (git mv)
- Modify: `Resources/Template/scripts/animations-catalog.ts` → `Resources/Template/scripts/effects-catalog.ts` (git mv + edit)
- Modify: `Resources/Template/src/lib/animations-catalog.spec.ts` → `Resources/Template/src/lib/effects-catalog.spec.ts` (git mv + edit)

**Interfaces:**
- Produces: `Resources/Template/integrations/effects.json` (28 entries after Tasks 14-17 add the new 12; 16 after this task), consumed by `EffectCatalog.load` (Task 1) and `effects-catalog.ts`'s `loadEffectsCatalog()` (used by Task 18's spec).
- Consumes: nothing.

- [ ] **Step 1: Rename the manifest and demo directory, add `version: 2`**

```bash
git mv Resources/Template/integrations/animations.json Resources/Template/integrations/effects.json
git mv Resources/Template/integrations/animations-demos Resources/Template/integrations/effects-demos
git mv Resources/Template/integrations/docs/animations.md Resources/Template/integrations/docs/effects.md
```

Edit `Resources/Template/integrations/effects.json`: change the top-level `"version": 1` to `"version": 2`. Leave all 16 `components` entries otherwise unchanged (no `placement` key — `EffectCatalogEntry.placement` decodes as `nil` when absent).

- [ ] **Step 2: Rename and extend `effects-catalog.ts`**

```bash
git mv Resources/Template/scripts/animations-catalog.ts Resources/Template/scripts/effects-catalog.ts
```

Replace its contents:

```typescript
// Resources/Template/scripts/effects-catalog.ts
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export type EffectCategory =
  | "text" | "cards" | "buttons" | "backgrounds" | "navigation"
  | "canvasBackground" | "cursorReactive" | "scrollDriven" | "generativeArt";

export interface EffectPlacement {
  kind: "inline" | "background";
  allowedParents: string[] | null;
}

export interface EffectCatalogEntry {
  component: string;
  title: string;
  ownerDescription: string;
  category: EffectCategory;
  keyProps: Record<string, string>;
  props: Record<string, unknown>;
  snippet: string;
  placement?: EffectPlacement;
}

export interface EffectsCatalog {
  version: number;
  components: EffectCatalogEntry[];
}

const HERE = dirname(fileURLToPath(import.meta.url));

export function catalogPath(): string {
  return resolve(HERE, "../integrations/effects.json");
}

export function loadEffectsCatalog(): EffectsCatalog {
  return JSON.parse(readFileSync(catalogPath(), "utf8")) as EffectsCatalog;
}

/** Entries with no `placement` — legacy `@astroanimate/core` micro-animations, copy-paste only. */
export function legacyEntries(catalog: EffectsCatalog): EffectCatalogEntry[] {
  return catalog.components.filter((e) => !e.placement);
}

/** Entries with `placement` — the 12 new hand-authored effects, each with a real
 *  `src/components/effects/<component>.astro` file. */
export function placeableEntries(catalog: EffectsCatalog): EffectCatalogEntry[] {
  return catalog.components.filter((e) => !!e.placement);
}
```

- [ ] **Step 3: Rename `effects-catalog.spec.ts`, scope it to legacy entries only**

```bash
git mv Resources/Template/src/lib/animations-catalog.spec.ts Resources/Template/src/lib/effects-catalog.spec.ts
```

Edit the file: change the import to `import { loadEffectsCatalog, legacyEntries } from "../../scripts/effects-catalog";`, change `const catalog = loadAnimationsCatalog();` to:

```typescript
const catalog = loadEffectsCatalog();
const legacy = legacyEntries(catalog);
```

Change every `catalog.components` loop in the file (the `describe(entry.component, ...)` block and the "never catalogs enhance=true" / "every curated component is documented" checks) to iterate `legacy` instead of `catalog.components` — the new 12 placeable entries are covered separately by Task 18's `effects-library.spec.ts` (they're hand-authored local files, not `@astroanimate/core` package imports, so they can't go through this file's `import(`@astroanimate/core/${entry.component}`)` path). Update the doc-consistency check's file path to `integrations/docs/effects.md`, and its demo-snapshot path to `../../integrations/effects-demos/${entry.component}.html`.

- [ ] **Step 4: Run the legacy suite**

Run (from `Resources/Template/`): `npm test -- effects-catalog.spec.ts`
Expected: PASS — all 16 legacy entries still render/snapshot/document correctly under the renamed paths.

- [ ] **Step 5: Run the Swift catalog tests from Task 1**

Run: `swift test --package-path . --filter EffectCatalogTests`
Expected: PASS — `loadsRealTemplateCatalog`, `groupsByCategory`, and `onlyNewCategoriesArePlaceable` now all pass against the renamed, 16-entry `effects.json`.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/integrations/effects.json Resources/Template/integrations/effects-demos \
        Resources/Template/integrations/docs/effects.md Resources/Template/scripts/effects-catalog.ts \
        Resources/Template/src/lib/effects-catalog.spec.ts
git commit -m "feat(#768): rename animations.json manifest to effects.json"
```

---

### Task 3: `PageModel` Codable types

**Files:**
- Create: `Sources/AnglesiteCore/PageModel.swift`
- Test: `Tests/AnglesiteCoreTests/PageModelTests.swift`

**Interfaces:**
- Produces: `public struct PageModel: Sendable, Equatable, Codable { public let version: String; public let path: String; public let tree: Node }` with nested `Node` (`id, kind: Kind, tag: String?, attrs: [Attr], span: Span, loc: Loc?, text: String?, children: [Node], block: BlockInfo?`), `Kind: String enum { fragment, element, component, expression, slot, text }`, `Attr { name: String, value: String? }`, `Span { start: Int?, end: Int? }` (positional `[start,end]` decode), `Loc { line: Int, column: Int }`, `BlockInfo { manifestPath: String, name: String, description: String, icon: String?, propEditors: [JSONValue], slots: [String] }`.
- Consumes: nothing (pure decode target for Task 4's `PageModelClient`).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/PageModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PageModelTests {
    @Test func decodesSidecarWireShape() throws {
        let json = """
        {
          "version": "sha256:abc",
          "path": "src/pages/index.astro",
          "tree": {
            "id": "n0", "kind": "fragment", "tag": null, "attrs": [], "span": [0, 100], "loc": null,
            "children": [
              {
                "id": "n1", "kind": "element", "tag": "section", "attrs": [{"name": "class", "value": "hero"}],
                "span": [0, 50], "loc": {"line": 1, "column": 1},
                "children": [
                  {"id": "n2", "kind": "text", "tag": null, "attrs": [], "span": [5, 10], "loc": null, "children": [], "text": "hi"}
                ]
              },
              {
                "id": "n3", "kind": "component", "tag": "Hcard", "attrs": [],
                "span": [50, 80], "loc": {"line": 5, "column": 1}, "children": [],
                "block": {"manifestPath": "src/components/Hcard.astro", "name": "Business Card", "description": "d", "icon": null, "propEditors": [], "slots": []}
              }
            ]
          }
        }
        """
        let model = try JSONDecoder().decode(PageModel.self, from: Data(json.utf8))
        #expect(model.version == "sha256:abc")
        #expect(model.tree.kind == .fragment)
        #expect(model.tree.children.count == 2)
        #expect(model.tree.children[0].tag == "section")
        #expect(model.tree.children[0].attrs.first?.value == "hero")
        #expect(model.tree.children[0].children.first?.text == "hi")
        #expect(model.tree.children[1].block?.name == "Business Card")
        #expect(model.tree.children[1].span.start == 50)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter PageModelTests`
Expected: FAIL — `PageModel` doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/PageModel.swift
import Foundation

/// Decoded response from the sidecar's `get_page_model` MCP tool: a block-annotated template
/// tree for one page (`server/page-model.mjs`'s `buildPageModel`). Node shape mirrors
/// ``ComponentModel/Node`` (same `toPublicNode` serializer on the sidecar side) plus a `block`
/// annotation on component instances that resolve to a `blocks.manifest.json` entry.
public struct PageModel: Sendable, Equatable, Codable {
    /// Content-hash version of the source this model was parsed from — passed back as
    /// `baseVersion` on the next edit so the sidecar can refuse a stale write.
    public let version: String
    /// Project-relative page path this model describes, e.g. `src/pages/index.astro`.
    public let path: String
    /// The page's template tree, rooted at a synthetic `.fragment` node.
    public let tree: Node

    public init(version: String, path: String, tree: Node) {
        self.version = version
        self.path = path
        self.tree = tree
    }

    public struct Node: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let kind: Kind
        public let tag: String?
        public let attrs: [Attr]
        public let span: Span
        public let loc: Loc?
        public let text: String?
        public let children: [Node]
        /// Present only when this node is a `.component` instance resolving to a
        /// `blocks.manifest.json` entry by its local import path.
        public let block: BlockInfo?

        public init(id: String, kind: Kind, tag: String?, attrs: [Attr], span: Span, loc: Loc?, text: String?, children: [Node], block: BlockInfo?) {
            self.id = id
            self.kind = kind
            self.tag = tag
            self.attrs = attrs
            self.span = span
            self.loc = loc
            self.text = text
            self.children = children
            self.block = block
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            tag = try c.decodeIfPresent(String.self, forKey: .tag)
            attrs = try c.decodeIfPresent([Attr].self, forKey: .attrs) ?? []
            span = try c.decodeIfPresent(Span.self, forKey: .span) ?? Span(start: nil, end: nil)
            loc = try c.decodeIfPresent(Loc.self, forKey: .loc)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
            block = try c.decodeIfPresent(BlockInfo.self, forKey: .block)
        }

        public enum Kind: String, Sendable, Codable {
            case fragment, element, component, expression, slot, text
        }
    }

    public struct Attr: Sendable, Equatable, Codable {
        public let name: String
        public let value: String?
        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// Wire format is a two-element array `[start, end]`, either may be null.
    public struct Span: Sendable, Equatable, Codable {
        public let start: Int?
        public let end: Int?

        public init(start: Int?, end: Int?) {
            self.start = start
            self.end = end
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decodeIfPresent(Int.self) ?? nil
            end = try c.decodeIfPresent(Int.self) ?? nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(start)
            try c.encode(end)
        }
    }

    public struct Loc: Sendable, Equatable, Codable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// Owner-facing metadata from `blocks.manifest.json`, annotated onto a resolved component
    /// instance by the sidecar's `annotateBlocks`.
    public struct BlockInfo: Sendable, Equatable, Codable {
        public let manifestPath: String
        public let name: String
        public let description: String
        public let icon: String?
        public let slots: [String]

        public init(manifestPath: String, name: String, description: String, icon: String?, slots: [String]) {
            self.manifestPath = manifestPath
            self.name = name
            self.description = description
            self.icon = icon
            self.slots = slots
        }

        enum CodingKeys: String, CodingKey {
            case manifestPath, name, description, icon, slots
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            manifestPath = try c.decode(String.self, forKey: .manifestPath)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decode(String.self, forKey: .description)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            slots = try c.decodeIfPresent([String].self, forKey: .slots) ?? []
        }
    }
}
```

Note: the fixture's `block.propEditors: []` is decoded and dropped — `PageModel.BlockInfo` doesn't need `propEditors` (nothing in this feature reads it; the sidecar may send it, `CodingKeys` above simply doesn't declare it, so `Decodable` ignores the extra key).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter PageModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PageModel.swift Tests/AnglesiteCoreTests/PageModelTests.swift
git commit -m "feat(#768): add PageModel Codable types for get_page_model"
```

---

### Task 4: `PageModelClient`

**Files:**
- Create: `Sources/AnglesiteCore/PageModelClient.swift`
- Test: `Tests/AnglesiteCoreTests/PageModelClientTests.swift`

**Interfaces:**
- Consumes: `PageModel` (Task 3), `MCPClient.ToolCallResult`/`MCPClient.callTool(name:arguments:)` shape (existing).
- Produces: `public struct PageModelClient: Sendable { public init(mcpClient: @escaping @Sendable () async -> MCPClient?); public init(toolCaller: @escaping ToolCaller); public func fetch(path: String) async throws -> PageModel; public enum ModelError: Error, Equatable { case notConnected, toolFailed(reason: String, detail: String), decodeFailed(String) } }` — used by Task 10's `EffectPlacementController`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/PageModelClientTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PageModelClientTests {
    @Test func fetchDecodesSuccessfulResult() async throws {
        let json = """
        {"version":"sha256:x","path":"src/pages/index.astro","tree":{"id":"n0","kind":"fragment","tag":null,"attrs":[],"span":[0,1],"loc":null,"children":[]}}
        """
        let client = PageModelClient { name, args in
            #expect(name == "get_page_model")
            #expect(args == .object(["path": .string("src/pages/index.astro")]))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: json)], isError: false)
        }
        let model = try await client.fetch(path: "src/pages/index.astro")
        #expect(model.version == "sha256:x")
        #expect(model.tree.id == "n0")
    }

    @Test func fetchThrowsToolFailedOnErrorResult() async throws {
        let client = PageModelClient { _, _ in
            MCPClient.ToolCallResult(
                content: [.init(type: "text", text: #"{"type":"anglesite:page-model-failed","reason":"read-failed","detail":"nope"}"#)],
                isError: true)
        }
        await #expect(throws: PageModelClient.ModelError.toolFailed(reason: "read-failed", detail: "nope")) {
            _ = try await client.fetch(path: "src/pages/missing.astro")
        }
    }

    @Test func fetchThrowsNotConnectedWhenNoClient() async throws {
        let client = PageModelClient(mcpClient: { nil })
        await #expect(throws: PageModelClient.ModelError.notConnected) {
            _ = try await client.fetch(path: "src/pages/index.astro")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter PageModelClientTests`
Expected: FAIL — `PageModelClient` doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/PageModelClient.swift
import Foundation

/// Fetches a page's structured model from the sidecar's `get_page_model` MCP tool. Same shape
/// as ``ComponentModelClient`` — same injection seam, same error taxonomy — deliberately, since
/// this is the same MCP round-trip pattern applied to a page instead of a component.
public struct PageModelClient: Sendable {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    private let toolCaller: ToolCaller

    /// Production initializer. Resolves the MCP client lazily per call (the connection comes up
    /// asynchronously after the site runtime starts).
    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw ModelError.notConnected }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    /// Test seam.
    public init(toolCaller: @escaping ToolCaller) {
        self.toolCaller = toolCaller
    }

    public enum ModelError: Error, Equatable {
        case notConnected
        case toolFailed(reason: String, detail: String)
        case decodeFailed(String)
    }

    /// Wire shape of `get_page_model`'s error content: `{type, reason, detail}`.
    private struct FailureEnvelope: Decodable {
        let reason: String
        let detail: String
    }

    /// Fetches the structured model for the page at project-relative `path` (e.g.
    /// `src/pages/index.astro`).
    ///
    /// - Throws: ``ModelError``.
    public func fetch(path: String) async throws -> PageModel {
        let result = try await toolCaller("get_page_model", .object(["path": .string(path)]))
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard !result.isError else {
            if let data = text.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: data) {
                throw ModelError.toolFailed(reason: envelope.reason, detail: envelope.detail)
            }
            throw ModelError.toolFailed(reason: "unknown", detail: text)
        }
        guard let data = text.data(using: .utf8) else { throw ModelError.decodeFailed("non-utf8 payload") }
        do {
            return try JSONDecoder().decode(PageModel.self, from: data)
        } catch {
            throw ModelError.decodeFailed(String(describing: error))
        }
    }
}

extension PageModelClient.ModelError {
    public var friendlyMessage: String {
        switch self {
        case .notConnected:
            return "Site is not running yet."
        case .toolFailed(let reason, let detail):
            switch reason {
            case "read-failed": return "Couldn't read this page: \(detail)"
            case "invalid-input": return detail
            case "parse-failed": return detail
            default: return "Something went wrong loading this page: \(detail)"
            }
        case .decodeFailed:
            return "Anglesite couldn't understand the page model returned by the plugin. Try updating the bundled plugin."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter PageModelClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PageModelClient.swift Tests/AnglesiteCoreTests/PageModelClientTests.swift
git commit -m "feat(#768): add PageModelClient for get_page_model round trip"
```

---

### Task 5: `insertBlock` op — `EditMessage.Op` constant + `ComponentStructureEditBuilder` builder

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift` (add one `Op` constant)
- Modify: `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift` (add `insertBlock` builder)
- Test: `Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift` (existing file — add cases; if it doesn't exist, create it)

**Interfaces:**
- Consumes: `EditMessage` (existing).
- Produces: `EditMessage.Op.insertBlock = "insertBlock"`; `ComponentStructureEditBuilder.insertBlock(id:path:baseVersion:parentId:index:manifestBlock:) -> EditMessage` — used by Task 10's `EffectPlacementController`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift (add to existing file, or create)
import Testing
@testable import AnglesiteCore

@Suite struct InsertBlockBuilderTests {
    @Test func buildsInsertBlockMessage() {
        let message = ComponentStructureEditBuilder.insertBlock(
            id: "e1", path: "src/pages/index.astro", baseVersion: "sha256:x",
            parentId: "n1", index: 2, manifestBlock: "Particle Field")
        #expect(message.op == "insertBlock")
        #expect(message.path == "src/pages/index.astro")
        #expect(message.selector == nil)
        guard case .object(let component)? = message.component else {
            Issue.record("expected object component payload")
            return
        }
        #expect(component["path"] == .string("src/pages/index.astro"))
        #expect(component["baseVersion"] == .string("sha256:x"))
        #expect(component["parentId"] == .string("n1"))
        #expect(component["index"] == .int(2))
        #expect(component["manifestBlock"] == .string("Particle Field"))
        #expect(component["node"] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter InsertBlockBuilderTests`
Expected: FAIL — `ComponentStructureEditBuilder.insertBlock` doesn't exist, `EditMessage.Op.insertBlock` doesn't exist.

- [ ] **Step 3: Add the `Op` constant**

In `Sources/AnglesiteCore/EditMessage.swift`, inside `public enum Op { ... }`, add (after `insertNode`):

```swift
        /// `"insertBlock"` — insert a `blocks.manifest.json`-registered block/component + its
        /// import at `{parentId, index}`, resolved server-side by owner-facing name. Carries a
        /// `component` payload with `manifestBlock` instead of `node`.
        public static let insertBlock = "insertBlock"
```

- [ ] **Step 4: Add the builder**

In `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift`, add (after `insertNode`):

```swift
    /// Builds the `insertBlock` message: insert the `blocks.manifest.json`-registered block
    /// named `manifestBlock` under `parentId` at child position `index`. The sidecar resolves
    /// `manifestBlock` to `{tag, componentPath}` itself and handles the frontmatter import —
    /// the caller only names the block, mirroring `insertNode`'s shape but without a `NodeSpec`.
    public static func insertBlock(
        id: String,
        path: String,
        baseVersion: String,
        parentId: String,
        index: Int,
        manifestBlock: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.insertBlock,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "parentId": .string(parentId),
                "index": .int(index),
                "manifestBlock": .string(manifestBlock),
            ]),
            value: nil
        )
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path . --filter InsertBlockBuilderTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Sources/AnglesiteCore/ComponentStructureEditBuilder.swift Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift
git commit -m "feat(#768): add insertBlock op constant and builder"
```

---

### Task 6: `PlacementPickMessage` + dispatcher/bridge wiring for a new message type

**Files:**
- Create: `Sources/AnglesiteCore/PlacementPickMessage.swift`
- Modify: `Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift`
- Modify: `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift`
- Test: `Tests/AnglesiteCoreTests/PlacementPickMessageTests.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift` (existing file — add cases)

**Interfaces:**
- Produces: `public struct AncestorInfo: Sendable, Equatable { tag, id: String?, classes: [String], nthChild: Int?, role: String?, ariaLabel: String? }`; `public struct ElementInfo: Sendable, Equatable { tag, id: String?, classes: [String], nthChild: Int, ancestors: [AncestorInfo], dataAnglesiteId: String?, dataTestId: String?, role: String?, ariaLabel: String?, textContent: String? }`; `public struct PlacementPickMessage: Sendable, Equatable { public static let messageType = "anglesite:pick-placement"; public let path: String; public let element: ElementInfo; public static func decode(from body: Any) -> Result<PlacementPickMessage, ComponentCanvasDecodeError> }`; `AnglesiteMessageDispatcher.DispatchResult` gains `.placementPickHandled` / `.placementPickDropped` cases and a `dispatch(...)` parameter `onPlacementPick: PlacementPickHandler? = nil` where `PlacementPickHandler = @Sendable (PlacementPickMessage) async -> Void`.
- Consumes: `ComponentCanvasDecodeError` (existing, reused).

- [ ] **Step 1: Write the failing test for `PlacementPickMessage`**

```swift
// Tests/AnglesiteCoreTests/PlacementPickMessageTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct PlacementPickMessageTests {
    @Test func decodesFullPayload() {
        let body: [String: Any] = [
            "type": "anglesite:pick-placement",
            "path": "/about/",
            "selector": [
                "tag": "SECTION", "id": "hero", "classes": ["hero", "hero--large"], "nthChild": 1,
                "ancestors": [
                    ["tag": "BODY", "classes": [] as [String], "nthChild": 1],
                    ["tag": "MAIN", "id": "content", "classes": [] as [String], "nthChild": 1],
                ],
                "role": "banner",
            ],
        ]
        guard case .success(let message) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected successful decode")
            return
        }
        #expect(message.path == "/about/")
        #expect(message.element.tag == "SECTION")
        #expect(message.element.id == "hero")
        #expect(message.element.classes == ["hero", "hero--large"])
        #expect(message.element.nthChild == 1)
        #expect(message.element.ancestors.count == 2)
        #expect(message.element.ancestors[0].tag == "BODY")
        #expect(message.element.ancestors[1].id == "content")
        #expect(message.element.role == "banner")
    }

    @Test func wrongTypeIsRejected() {
        let body: [String: Any] = ["type": "anglesite:apply-edit", "path": "/", "selector": [String: Any]()]
        guard case .failure(let error) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .wrongType)
    }

    @Test func missingSelectorIsMalformed() {
        let body: [String: Any] = ["type": "anglesite:pick-placement", "path": "/"]
        guard case .failure(let error) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .malformed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter PlacementPickMessageTests`
Expected: FAIL — `PlacementPickMessage` doesn't exist.

- [ ] **Step 3: Write `PlacementPickMessage.swift`**

```swift
// Sources/AnglesiteCore/PlacementPickMessage.swift
import Foundation

/// One ancestor in a clicked element's root-first chain, as collected by the overlay's
/// `elementInfoFor()`/`collectAncestors()` (JS/edit-overlay/src/selector.ts). Mirrors
/// `AncestorInfo` there field-for-field.
public struct AncestorInfo: Sendable, Equatable {
    public let tag: String
    public let id: String?
    public let classes: [String]
    public let nthChild: Int?
    public let role: String?
    public let ariaLabel: String?

    public init(tag: String, id: String?, classes: [String], nthChild: Int?, role: String?, ariaLabel: String?) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.nthChild = nthChild
        self.role = role
        self.ariaLabel = ariaLabel
    }

    /// Decodes one entry from the wire's `ancestors` array. Returns `nil` (skipped by the
    /// caller) rather than throwing on a malformed entry — a best-effort ancestor chain is
    /// still useful to `PlacementMatcher` even if one hop is missing fields.
    static func decode(from dict: [String: Any]) -> AncestorInfo? {
        guard let tag = dict["tag"] as? String else { return nil }
        return AncestorInfo(
            tag: tag,
            id: dict["id"] as? String,
            classes: dict["classes"] as? [String] ?? [],
            nthChild: dict["nthChild"] as? Int,
            role: dict["role"] as? String,
            ariaLabel: dict["ariaLabel"] as? String
        )
    }
}

/// Structured element metadata collected by the overlay's `elementInfoFor()` — the same shape
/// `EditMessage.selector` relays opaquely to the sidecar's `selector.mjs`, but here decoded
/// field-by-field because `PlacementMatcher` (Task 7) interprets it client-side against a
/// fetched `PageModel` instead of forwarding it server-side.
public struct ElementInfo: Sendable, Equatable {
    public let tag: String
    public let id: String?
    public let classes: [String]
    public let nthChild: Int
    /// Root-first ancestor chain, stopping at (and including) `<body>`.
    public let ancestors: [AncestorInfo]
    public let dataAnglesiteId: String?
    public let dataTestId: String?
    public let role: String?
    public let ariaLabel: String?
    public let textContent: String?

    public init(tag: String, id: String?, classes: [String], nthChild: Int, ancestors: [AncestorInfo], dataAnglesiteId: String?, dataTestId: String?, role: String?, ariaLabel: String?, textContent: String?) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.nthChild = nthChild
        self.ancestors = ancestors
        self.dataAnglesiteId = dataAnglesiteId
        self.dataTestId = dataTestId
        self.role = role
        self.ariaLabel = ariaLabel
        self.textContent = textContent
    }

    static func decode(from dict: [String: Any]) -> ElementInfo? {
        guard let tag = dict["tag"] as? String, let nthChild = dict["nthChild"] as? Int else { return nil }
        let ancestorDicts = dict["ancestors"] as? [[String: Any]] ?? []
        return ElementInfo(
            tag: tag,
            id: dict["id"] as? String,
            classes: dict["classes"] as? [String] ?? [],
            nthChild: nthChild,
            ancestors: ancestorDicts.compactMap(AncestorInfo.decode(from:)),
            dataAnglesiteId: dict["dataAnglesiteId"] as? String,
            dataTestId: dict["dataTestId"] as? String,
            role: dict["role"] as? String,
            ariaLabel: dict["ariaLabel"] as? String,
            textContent: dict["textContent"] as? String
        )
    }
}

/// The overlay's placement-pick mode (Task 9) reporting a click on an arbitrary element while
/// the app is placing an effect. Distinct from `anglesite:apply-edit` — no reply is sent back
/// into the page; the whole match/apply/refresh flow (Task 10) runs natively and updates the
/// app's own placement HUD.
public struct PlacementPickMessage: Sendable, Equatable {
    public static let messageType = "anglesite:pick-placement"

    public let path: String
    public let element: ElementInfo

    public init(path: String, element: ElementInfo) {
        self.path = path
        self.element = element
    }

    /// Decodes a `WKScriptMessage` body. Returns `.failure(.wrongType)` for another message's
    /// body so the dispatcher can try the next decoder; `.malformed` when `type` matches but
    /// `path`/`selector` (or `selector`'s required `tag`/`nthChild`) are missing.
    public static func decode(from body: Any) -> Result<PlacementPickMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let path = dict["path"] as? String,
              let selectorDict = dict["selector"] as? [String: Any],
              let element = ElementInfo.decode(from: selectorDict) else {
            return .failure(.malformed)
        }
        return .success(PlacementPickMessage(path: path, element: element))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter PlacementPickMessageTests`
Expected: PASS

- [ ] **Step 5: Wire the 5th message type into `AnglesiteMessageDispatcher`**

In `Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift`:

Add to the doc comment's numbered list: `5. anglesite:pick-placement (a PlacementPickMessage) — dispatched to the optional onPlacementPick callback. No reply.`

Add a typealias next to `ComputedStylesHandler`:
```swift
    /// Receives a decoded `anglesite:pick-placement` message (message type 5 above).
    public typealias PlacementPickHandler = @Sendable (PlacementPickMessage) async -> Void
```

Add cases to `DispatchResult`:
```swift
        /// `anglesite:pick-placement` was forwarded to the optional handler.
        case placementPickHandled
        /// `anglesite:pick-placement` arrived but no `onPlacementPick` handler is installed.
        case placementPickDropped
```

Add to `RejectionReason`:
```swift
            /// `anglesite:pick-placement` matched but the payload failed to decode.
            case placementPickDecode(ComponentCanvasDecodeError)
```

Add a parameter to `dispatch(...)`:
```swift
    public static func dispatch(
        body: Any,
        via router: EditRouter,
        onVisibleElements: VisibleElementsHandler? = nil,
        onCanvasSelection: CanvasSelectionHandler? = nil,
        onComputedStyles: ComputedStylesHandler? = nil,
        onPlacementPick: PlacementPickHandler? = nil
    ) async -> DispatchResult {
```

Add a case to the `switch typeStr` (after the `ComputedStylesReport.messageType` case, before `default`):
```swift
        case PlacementPickMessage.messageType:
            switch PlacementPickMessage.decode(from: body) {
            case .success(let message):
                guard let handler = onPlacementPick else { return .placementPickDropped }
                await handler(message)
                return .placementPickHandled
            case .failure(let error):
                return .rejected(.placementPickDecode(error))
            }
```

- [ ] **Step 6: Wire `onPlacementPick` through `AnglesiteScriptHandler`**

In `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift`, mirror every existing `onCanvasSelection` occurrence found in Step-6-of-research (the stored property, the two-init parameter, the `dispatch(...)` forwarding call, and the `case .canvasSelectionHandled, .canvasSelectionDropped:` no-op branch): add a matching `onPlacementPick: PlacementPickHandler?` stored property, constructor parameter, forwarding argument, and a `case .placementPickHandled, .placementPickDropped: break` (or whatever the existing no-op branches do — match their exact style) branch in the result switch.

- [ ] **Step 7: Add a dispatcher-level test**

In `Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift`, add:

```swift
    @Test func routesPlacementPickToHandler() async {
        var received: PlacementPickMessage?
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/about/",
            "selector": ["tag": "SECTION", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: body, via: FakeEditRouter(),
            onPlacementPick: { received = $0 })
        #expect(result == .placementPickHandled)
        #expect(received?.path == "/about/")
    }

    @Test func placementPickDroppedWithoutHandler() async {
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/",
            "selector": ["tag": "DIV", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(body: body, via: FakeEditRouter())
        #expect(result == .placementPickDropped)
    }
```

(Reuse whatever `FakeEditRouter` test double the existing suite already defines for the other handler tests — do not redefine it.)

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --package-path . --filter PlacementPickMessageTests`
Run: `swift test --package-path . --filter AnglesiteMessageDispatcherTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/PlacementPickMessage.swift Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift \
        Sources/AnglesiteBridge/AnglesiteScriptHandler.swift Tests/AnglesiteCoreTests/PlacementPickMessageTests.swift \
        Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift
git commit -m "feat(#768): add anglesite:pick-placement message type"
```

---

### Task 7: `PlacementMatcher` — resolve a click to a `PageModel` node

**Files:**
- Create: `Sources/AnglesiteCore/PlacementMatcher.swift`
- Test: `Tests/AnglesiteCoreTests/PlacementMatcherTests.swift`

**Interfaces:**
- Consumes: `ElementInfo`/`AncestorInfo` (Task 6), `PageModel`/`PageModel.Node` (Task 3), `EffectCatalogEntry.Placement` (Task 1).
- Produces: `public enum PlacementMatcher { public static func resolve(element: ElementInfo, in model: PageModel, placement: EffectCatalogEntry.Placement) -> Result<Insertion, MatchError> }` with `public struct Insertion: Equatable { public let parentId: String; public let index: Int }` and `public enum MatchError: Error, Equatable { case noMatch, ambiguous }` — used by Task 10.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/PlacementMatcherTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct PlacementMatcherTests {
    /// `<body id="body"><header></header><section class="hero">target</section><footer></footer></body>`
    /// as a two-level PageModel tree: fragment(n0) -> body(n1) -> [header(n2), section.hero(n3), footer(n4)]
    static func fixtureModel() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let body = node("n1", kind: .element, tag: "BODY", attrs: [.init(name: "id", value: "body")], children: [
            node("n2", kind: .element, tag: "HEADER"),
            node("n3", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "hero")]),
            node("n4", kind: .element, tag: "FOOTER"),
        ])
        let root = node("n0", kind: .fragment, tag: nil, children: [body])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    static func elementInfo(tag: String, classes: [String] = [], nthChild: Int, ancestorTags: [(String, String?)]) -> ElementInfo {
        ElementInfo(
            tag: tag, id: nil, classes: classes, nthChild: nthChild,
            ancestors: ancestorTags.map { AncestorInfo(tag: $0.0, id: $0.1, classes: [], nthChild: nil, role: nil, ariaLabel: nil) },
            dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil)
    }

    @Test func inlinePlacementInsertsAfterMatchedNode() {
        let element = elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 2) // after n3 (index 1 among [n2,n3,n4]) -> insert at 2
    }

    @Test func backgroundPlacementInsertsAsFirstChildOfParent() {
        let element = elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .background, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 0)
    }

    @Test func noMatchWhenTagAndAncestryDontLineUp() {
        let element = elementInfo(tag: "ARTICLE", nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        #expect(result == .failure(.noMatch))
    }

    @Test func allowedParentsRestrictsMatch() {
        let element = elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: ["MAIN"])
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        #expect(result == .failure(.noMatch)) // parent is BODY, not MAIN
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter PlacementMatcherTests`
Expected: FAIL — `PlacementMatcher` doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/PlacementMatcher.swift
import Foundation

/// Resolves a live-preview click's ``ElementInfo`` to an insertion point in a fetched
/// ``PageModel`` — the bridge between the overlay's click-to-select infrastructure (which knows
/// nothing about node ids) and `insertBlock`'s `{parentId, index}` addressing (which knows
/// nothing about DOM clicks). Mirrors the sidecar's `selector.mjs` ancestor-walk priority so a
/// match here would resolve to the same element `selector.mjs` would pick for a page-level
/// selector op — deliberately duplicated (in Swift, not called into the sidecar) because this
/// resolution happens client-side against an already-fetched tree, with no extra round trip.
public enum PlacementMatcher {
    public struct Insertion: Equatable {
        public let parentId: String
        public let index: Int

        public init(parentId: String, index: Int) {
            self.parentId = parentId
            self.index = index
        }
    }

    public enum MatchError: Error, Equatable {
        /// No node in the tree matches the clicked element's tag + position + ancestry.
        case noMatch
        /// More than one node matches — refuse rather than guess which one the owner meant.
        case ambiguous
    }

    /// Finds the node matching `element` in `model.tree`, then computes the insertion point per
    /// `placement.kind`: `.inline` inserts immediately after the matched node (same parent,
    /// index + 1); `.background` inserts as the first child (index 0) of the matched node's
    /// *parent* — behind it, not adjacent. `placement.allowedParents`, when non-nil, restricts
    /// matches to nodes whose immediate parent's tag is in the list.
    public static func resolve(element: ElementInfo, in model: PageModel, placement: EffectCatalogEntry.Placement) -> Result<Insertion, MatchError> {
        var matches: [(node: PageModel.Node, parentId: String, indexInParent: Int)] = []
        collectMatches(node: model.tree, parentId: nil, element: element, allowedParents: placement.allowedParents, into: &matches)
        guard !matches.isEmpty else { return .failure(.noMatch) }
        guard matches.count == 1 else { return .failure(.ambiguous) }
        let match = matches[0]
        switch placement.kind {
        case .inline:
            return .success(Insertion(parentId: match.parentId, index: match.indexInParent + 1))
        case .background:
            return .success(Insertion(parentId: match.parentId, index: 0))
        }
    }

    /// Depth-first walk collecting every node whose tag, `nthChild` position among its element
    /// siblings, and immediate-parent tag (if `allowedParents` is set) line up with `element`.
    /// Ancestor chain is consulted only to break ties when more than one node shares the same
    /// (tag, nthChild) pair at different depths — the common case (one match) never needs it.
    private static func collectMatches(
        node: PageModel.Node, parentId: String?, element: ElementInfo, allowedParents: [String]?,
        into matches: inout [(node: PageModel.Node, parentId: String, indexInParent: Int)]
    ) {
        let elementSiblings = node.children.filter { $0.kind == .element || $0.kind == .component }
        for (index, child) in elementSiblings.enumerated() {
            let position = index + 1 // 1-based, matches CSS :nth-child / the overlay's nthChild
            if child.tag?.uppercased() == element.tag.uppercased(), position == element.nthChild {
                if allowedParents == nil || allowedParents!.map { $0.uppercased() }.contains(node.tag?.uppercased() ?? "") {
                    matches.append((child, node.id, index))
                }
            }
        }
        for child in node.children {
            collectMatches(node: child, parentId: node.id, element: element, allowedParents: allowedParents, into: &matches)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter PlacementMatcherTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/PlacementMatcher.swift Tests/AnglesiteCoreTests/PlacementMatcherTests.swift
git commit -m "feat(#768): add PlacementMatcher to resolve clicks to page-model nodes"
```

---

### Task 8: `BlockManifestSync`

**Files:**
- Create: `Sources/AnglesiteCore/BlockManifestSync.swift`
- Create: `Resources/Template/blocks.manifest.json` (empty `modules: []` for now — Tasks 14-17 append entries)
- Test: `Tests/AnglesiteCoreTests/BlockManifestSyncTests.swift`

**Interfaces:**
- Produces: `public enum BlockManifestSync { public static func sync(templateBlocksManifest: URL, siteBlocksManifest: URL) throws }` — reads the template's canonical manifest and the site's own (creating it if absent), appends any `modules` entry (matched by `path`) missing from the site's copy, leaves existing entries and any owner-added entries untouched. Used by Task 12's `SiteWindowModel` wiring.
- Consumes: the `blocks.manifest.json` schema (`{schemaVersion: "anglesite-block-manifest/1", modules: [{path, export, kind, name, description, icon, propEditors, slots, placement}]}` — matches the sidecar's `block-manifest-schema.mjs`, decoded here as a generic `[String: JSONValue]` array so this file doesn't need to model every field, only `path` for the merge key).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/BlockManifestSyncTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BlockManifestSyncTests {
    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func createsManifestWhenSiteHasNone() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let templateManifest = tmp.appendingPathComponent("template/blocks.manifest.json")
        let siteManifest = tmp.appendingPathComponent("site/blocks.manifest.json")
        try write(#"{"schemaVersion":"anglesite-block-manifest/1","modules":[{"path":"src/components/effects/ParticleField.astro","export":"ParticleField","kind":"astro","name":"Particle Field","description":"d","icon":null,"propEditors":[],"slots":[]}]}"#, to: templateManifest)

        try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)

        let written = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(written.contains("ParticleField"))
    }

    @Test func appendsOnlyMissingEntriesByPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let templateManifest = tmp.appendingPathComponent("template/blocks.manifest.json")
        let siteManifest = tmp.appendingPathComponent("site/blocks.manifest.json")
        try write(#"{"schemaVersion":"anglesite-block-manifest/1","modules":[
            {"path":"src/components/effects/ParticleField.astro","export":"ParticleField","kind":"astro","name":"Particle Field","description":"d","icon":null,"propEditors":[],"slots":[]},
            {"path":"src/components/effects/AuroraGradient.astro","export":"AuroraGradient","kind":"astro","name":"Aurora Gradient","description":"d","icon":null,"propEditors":[],"slots":[]}
        ]}"#, to: templateManifest)
        try write(#"{"schemaVersion":"anglesite-block-manifest/1","modules":[
            {"path":"src/components/effects/ParticleField.astro","export":"ParticleField","kind":"astro","name":"CUSTOMIZED BY OWNER","description":"d","icon":null,"propEditors":[],"slots":[]}
        ]}"#, to: siteManifest)

        try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)

        let written = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(written.contains("CUSTOMIZED BY OWNER")) // untouched
        #expect(written.contains("AuroraGradient")) // appended
        #expect(written.components(separatedBy: "ParticleField").count == 2) // not duplicated (1 occurrence -> split gives 2 pieces)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter BlockManifestSyncTests`
Expected: FAIL — `BlockManifestSync` doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/BlockManifestSync.swift
import Foundation

/// Keeps a site's `blocks.manifest.json` up to date with the app's shipped effect components.
/// New sites get the template's manifest copied in wholesale by the scaffold script; this covers
/// sites created before an effect existed. Never touches an entry it didn't write itself — an
/// owner is free to hand-edit or remove any entry, and a later sync leaves that alone, only
/// filling in entries genuinely missing by `path`. This is a plain JSON merge, not sidecar code:
/// `blocks.manifest.json` is a project-root data file the sidecar only *reads*.
public enum BlockManifestSync {
    public enum SyncError: Error {
        case invalidTemplateManifest
    }

    /// Merges `templateBlocksManifest`'s `modules` into `siteBlocksManifest`, creating the site
    /// file if absent, appending only entries whose `path` isn't already present.
    public static func sync(templateBlocksManifest: URL, siteBlocksManifest: URL) throws {
        let templateData = try Data(contentsOf: templateBlocksManifest)
        guard let templateManifest = try JSONSerialization.jsonObject(with: templateData) as? [String: Any],
              let templateModules = templateManifest["modules"] as? [[String: Any]] else {
            throw SyncError.invalidTemplateManifest
        }

        var siteManifest: [String: Any]
        var siteModules: [[String: Any]]
        if let siteData = try? Data(contentsOf: siteBlocksManifest),
           let decoded = try? JSONSerialization.jsonObject(with: siteData) as? [String: Any],
           let modules = decoded["modules"] as? [[String: Any]] {
            siteManifest = decoded
            siteModules = modules
        } else {
            siteManifest = ["schemaVersion": "anglesite-block-manifest/1", "modules": [[String: Any]]()]
            siteModules = []
        }

        let existingPaths = Set(siteModules.compactMap { $0["path"] as? String })
        for entry in templateModules {
            guard let path = entry["path"] as? String, !existingPaths.contains(path) else { continue }
            siteModules.append(entry)
        }
        siteManifest["modules"] = siteModules

        let output = try JSONSerialization.data(withJSONObject: siteManifest, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: siteBlocksManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: siteBlocksManifest, options: .atomic)
    }
}
```

- [ ] **Step 4: Create the (initially empty) template manifest**

```json
{
  "schemaVersion": "anglesite-block-manifest/1",
  "modules": []
}
```
Write this to `Resources/Template/blocks.manifest.json`. (Tasks 14-17 append the 12 real entries; leaving it empty here keeps this task's test-driven change minimal and independently mergeable.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path . --filter BlockManifestSyncTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/BlockManifestSync.swift Resources/Template/blocks.manifest.json Tests/AnglesiteCoreTests/BlockManifestSyncTests.swift
git commit -m "feat(#768): add BlockManifestSync to merge blocks.manifest.json"
```

---

### Task 9: Overlay placement-pick mode (`JS/edit-overlay`)

**Files:**
- Modify: `JS/edit-overlay/src/messages.ts`
- Modify: `JS/edit-overlay/src/overlay.ts`
- Test: `JS/edit-overlay/src/overlay.spec.ts` (existing file — add cases; check the exact filename via `ls JS/edit-overlay/src/*.spec.ts` before editing, since the plan can't see the live directory)

**Interfaces:**
- Produces: `messages.ts` gains `export interface PlacementPickMessage { id: string; type: "anglesite:pick-placement"; path: string; selector: ElementInfo }` and `export function postPlacementPick(message: PlacementPickMessage, win?: WebKitWindow): boolean`. `overlay.ts` gains `export function enterPlacementMode(): void` / `export function exitPlacementMode(): void`, installed on `window.anglesite._enterPlacementMode` / `window.anglesite._exitPlacementMode` (same pattern `installReplyHandler` uses to install `_handleReply`), plus internal click wiring that fires only while placement mode is active.
- Consumes: `elementInfoFor` (existing, `selector.ts`), `nextEditID` (existing, `messages.ts`).

- [ ] **Step 1: Write the failing test**

Add to the overlay's existing spec file:

```typescript
// (append to the existing overlay spec file)
import { installPlacementPickMode } from "./overlay.js";

describe("placement-pick mode", () => {
  function makeWin() {
    const posted: unknown[] = [];
    const win = {
      webkit: { messageHandlers: { anglesite: { postMessage: (body: unknown) => posted.push(body) } } },
    } as unknown as Window & typeof globalThis;
    return { win, posted };
  }

  it("does nothing on click when not in placement mode", () => {
    document.body.innerHTML = `<div id="target">hi</div>`;
    const { win, posted } = makeWin();
    installPlacementPickMode(win);
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(0);
  });

  it("reports a click on any element while in placement mode, then stops after exit", () => {
    document.body.innerHTML = `<div id="target">hi</div>`;
    const { win, posted } = makeWin();
    const controls = installPlacementPickMode(win);
    controls.enter();
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1);
    expect((posted[0] as { type: string }).type).toBe("anglesite:pick-placement");
    expect((posted[0] as { selector: { tag: string } }).selector.tag).toBe("DIV");

    controls.exit();
    (document.getElementById("target") as HTMLElement).click();
    expect(posted).toHaveLength(1); // no new post after exit
  });

  it("does not interfere with EDITABLE_TAG click-to-edit outside placement mode", () => {
    document.body.innerHTML = `<p id="p">edit me</p>`;
    const { win } = makeWin();
    installPlacementPickMode(win);
    const p = document.getElementById("p") as HTMLElement;
    p.click();
    expect(p.isContentEditable).toBe(false); // attachClickToEdit isn't installed by this helper; this just confirms no placement-mode side effect leaks
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `JS/edit-overlay/`): `npm test`
Expected: FAIL — `installPlacementPickMode` doesn't exist.

- [ ] **Step 3: Add `postPlacementPick` to `messages.ts`**

Add to `JS/edit-overlay/src/messages.ts` (after `EditMessage`/`postEdit`):

```typescript
export interface PlacementPickMessage {
  id: string;
  type: "anglesite:pick-placement";
  path: string;
  selector: ElementInfo;
}

/** Posts a placement-pick report to native. No reply is awaited — the whole match/apply flow
 *  runs natively and updates the app's own placement HUD, not the page. */
export function postPlacementPick(
  message: PlacementPickMessage,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.anglesite;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}
```

(`ElementInfo` is already imported at the top of `messages.ts` — reuse that import.)

- [ ] **Step 4: Add placement-pick mode to `overlay.ts`**

Add to `JS/edit-overlay/src/overlay.ts` (after `attachClickToEdit`):

```typescript
export interface PlacementPickControls {
  enter(): void;
  exit(): void;
}

/** Placement-pick mode: while active, a click on ANY element (not just EDITABLE_TAG) reports its
 *  ElementInfo via `anglesite:pick-placement` instead of the normal click-to-edit path. Entered
 *  only via an explicit native call (`window.anglesite._enterPlacementMode()`), never ambient —
 *  outside this mode, ordinary click-to-edit behavior (`attachClickToEdit`) is unaffected. */
export function installPlacementPickMode(win: Window & typeof globalThis = window): PlacementPickControls {
  let active = false;

  const handler = (ev: MouseEvent) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    ev.preventDefault();
    ev.stopPropagation();
    postPlacementPick(
      {
        id: nextEditID(),
        type: "anglesite:pick-placement",
        path: location.pathname,
        selector: elementInfoFor(target),
      },
      win as unknown as Parameters<typeof postPlacementPick>[1],
    );
  };
  document.addEventListener("click", handler, { capture: true });

  const anglesiteWin = win as unknown as { anglesite?: { _enterPlacementMode?: () => void; _exitPlacementMode?: () => void } };
  anglesiteWin.anglesite = anglesiteWin.anglesite ?? {};
  const controls: PlacementPickControls = {
    enter: () => { active = true; },
    exit: () => { active = false; },
  };
  anglesiteWin.anglesite._enterPlacementMode = controls.enter;
  anglesiteWin.anglesite._exitPlacementMode = controls.exit;
  return controls;
}
```

Add `installPlacementPickMode(window);` to the module's install-once bootstrap block (find where `attachClickToEdit(awaitReply)` and `installVisibleElementsReporter()` are currently called — likely near the bottom of `overlay.ts` or in `index.ts` — and add the new call alongside them, gated by the same `INSTALLED_FLAG` guard those calls already sit behind).

- [ ] **Step 5: Run test to verify it passes**

Run (from `JS/edit-overlay/`): `npm run lint && npm run typecheck && npm test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add JS/edit-overlay/src/messages.ts JS/edit-overlay/src/overlay.ts JS/edit-overlay/src/*.spec.ts
git commit -m "feat(#768): add overlay placement-pick mode"
```

---

### Task 10: `EffectPlacementController` — orchestrate the click-to-place flow

**Files:**
- Create: `Sources/AnglesiteApp/EffectPlacementController.swift`
- Test: `Tests/AnglesiteAppTests/EffectPlacementControllerTests.swift`

**Interfaces:**
- Consumes: `PageModelClient` (Task 4), `PlacementMatcher` (Task 7), `ComponentStructureEditBuilder.insertBlock` (Task 5), `EditRouter`/`MCPApplyEditRouter` (existing), `EffectCatalogEntry` (Task 1), `PlacementPickMessage` (Task 6).
- Produces: `@MainActor @Observable final class EffectPlacementController` with `enum State: Equatable { case idle, picking(entry: EffectCatalogEntry), applying, succeeded, failed(String) }`, `var state: State`, `func startPlacement(for entry: EffectCatalogEntry, enterOverlayMode: @escaping () -> Void, exitOverlayMode: @escaping () -> Void)`, `func cancel()`, `func handlePick(_ message: PlacementPickMessage) async` — called from Task 12's wiring of `AnglesiteScriptHandler`'s `onPlacementPick`. Used by Task 11's gallery view.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteAppTests/EffectPlacementControllerTests.swift
import Testing
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite @MainActor struct EffectPlacementControllerTests {
    static let entry = EffectCatalogEntry(
        component: "ParticleField", title: "Particle Field", ownerDescription: "d",
        category: .canvasBackground, keyProps: [:], snippet: "s",
        placement: .init(kind: .background, allowedParents: nil))

    static let modelJSON = """
    {"version":"sha256:x","path":"src/pages/index.astro","tree":{"id":"n0","kind":"fragment","tag":null,"attrs":[],"span":[0,1],"loc":null,"children":[
      {"id":"n1","kind":"element","tag":"BODY","attrs":[],"span":[0,1],"loc":null,"children":[
        {"id":"n2","kind":"element","tag":"SECTION","attrs":[{"name":"class","value":"hero"}],"span":[0,1],"loc":null,"children":[]}
      ]}
    ]}}
    """

    @Test func fullFlowAppliesInsertBlock() async {
        var appliedOp: String?
        var enteredOverlay = false
        var exitedOverlay = false
        let router = TestEditRouter { message in
            appliedOp = message.op
            return EditReply(id: message.id, status: .applied, message: nil)
        }
        let pageModelClient = PageModelClient { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(
            path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: router)

        controller.startPlacement(for: Self.entry, enterOverlayMode: { enteredOverlay = true }, exitOverlayMode: { exitedOverlay = true })
        #expect(enteredOverlay)
        guard case .picking = controller.state else {
            Issue.record("expected .picking")
            return
        }

        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "SECTION", id: nil, classes: ["hero"], nthChild: 1, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        await controller.handlePick(click)

        #expect(exitedOverlay)
        #expect(appliedOp == "insertBlock")
        #expect(controller.state == .succeeded)
    }

    @Test func noMatchSetsFailedState() async {
        let router = TestEditRouter { _ in Issue.record("apply should not be called"); return EditReply(id: "x", status: .failed, message: nil) }
        let pageModelClient = PageModelClient { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: Self.modelJSON)], isError: false)
        }
        let controller = EffectPlacementController(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: router)
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: {})

        let click = PlacementPickMessage(
            path: "/", element: .init(tag: "ARTICLE", id: nil, classes: [], nthChild: 9, ancestors: [], dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil))
        await controller.handlePick(click)

        guard case .failed = controller.state else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test func cancelReturnsToIdleAndExitsOverlay() {
        var exited = false
        let controller = EffectPlacementController(
            path: "src/pages/index.astro",
            pageModelClient: PageModelClient { _, _ in MCPClient.ToolCallResult(content: [], isError: false) },
            editRouter: TestEditRouter { _ in EditReply(id: "x", status: .applied, message: nil) })
        controller.startPlacement(for: Self.entry, enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.cancel()
        #expect(exited)
        #expect(controller.state == .idle)
    }
}

/// Minimal `EditRouter` test double — reuse an existing one if `AnglesiteAppTests` already
/// defines one with this shape; otherwise add this alongside the test.
private struct TestEditRouter: EditRouter {
    let onApply: (EditMessage) -> EditReply
    func apply(_ message: EditMessage) async -> EditReply { onApply(message) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter EffectPlacementControllerTests`
Expected: FAIL — `EffectPlacementController` doesn't exist. (If `AnglesiteAppTests` already declares a differently-shaped `TestEditRouter`/fake, reuse it and delete the private one above instead of having two.)

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteApp/EffectPlacementController.swift
import Foundation
import AnglesiteCore

/// Drives the click-to-place flow for one effect: enters overlay placement-pick mode, waits for
/// a click, resolves it against a freshly-fetched `PageModel` via `PlacementMatcher`, and applies
/// the resulting `insertBlock` edit. One instance per site window (constructed alongside
/// `PageModelClient`/`editRouter` in `SiteWindowModel`, Task 12); `startPlacement`/`cancel` are
/// idempotent no-ops when called out of turn (e.g. a stray double-click).
@MainActor
@Observable
public final class EffectPlacementController {
    public enum State: Equatable {
        case idle
        case picking(entry: EffectCatalogEntry)
        case applying
        case succeeded
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let path: String
    private let pageModelClient: PageModelClient
    private let editRouter: any EditRouter
    private var exitOverlayMode: (() -> Void)?

    public init(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter) {
        self.path = path
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }

    /// Enters placement-pick mode for `entry`. `enterOverlayMode`/`exitOverlayMode` are the
    /// caller's bridge into the live preview's `window.anglesite._enterPlacementMode()` /
    /// `_exitPlacementMode()` (Task 9) — kept as closures so this type has no WKWebView
    /// dependency and stays unit-testable.
    public func startPlacement(for entry: EffectCatalogEntry, enterOverlayMode: @escaping () -> Void, exitOverlayMode: @escaping () -> Void) {
        guard case .idle = state else { return }
        self.exitOverlayMode = exitOverlayMode
        state = .picking(entry: entry)
        enterOverlayMode()
    }

    /// Cancels an in-progress pick (Esc / Cancel button), exiting overlay mode and returning to
    /// `.idle`. A no-op if nothing is in progress.
    public func cancel() {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .idle
    }

    /// Handles a reported placement click: fetches the current page model, matches the click,
    /// builds and applies the `insertBlock` edit. Always exits overlay mode on return, success
    /// or failure — a picking session is one click.
    public func handlePick(_ message: PlacementPickMessage) async {
        guard case .picking(let entry) = state, let placement = entry.placement else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .applying

        do {
            let model = try await pageModelClient.fetch(path: path)
            switch PlacementMatcher.resolve(element: message.element, in: model, placement: placement) {
            case .success(let insertion):
                let edit = ComponentStructureEditBuilder.insertBlock(
                    id: UUID().uuidString, path: path, baseVersion: model.version,
                    parentId: insertion.parentId, index: insertion.index, manifestBlock: entry.title)
                let reply = await editRouter.apply(edit)
                switch reply.status {
                case .applied:
                    state = .succeeded
                case .failed, .ambiguous, .preview:
                    state = .failed(reply.message ?? "The edit was refused.")
                }
            case .failure(.noMatch):
                state = .failed("Couldn't find that spot on the page — try clicking a different element.")
            case .failure(.ambiguous):
                state = .failed("That spot matched more than one place on the page — try a more specific element.")
            }
        } catch let error as PageModelClient.ModelError {
            state = .failed(error.friendlyMessage)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter EffectPlacementControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/EffectPlacementController.swift Tests/AnglesiteAppTests/EffectPlacementControllerTests.swift
git commit -m "feat(#768): add EffectPlacementController orchestrating click-to-place"
```

---

### Task 11: Rename `AnimationsGalleryView` → `EffectsGalleryView`, add Apply-to-page + placement HUD

**Files:**
- Modify → Create: `Sources/AnglesiteApp/AnimationsGalleryView.swift` → `Sources/AnglesiteApp/EffectsGalleryView.swift` (git mv + edit)

**Interfaces:**
- Consumes: `EffectCatalog`/`EffectCatalogEntry`/`EffectCategory` (Task 1), `EffectPlacementController` (Task 10).
- Produces: `struct EffectsGalleryView: View` taking an injected `EffectPlacementController` (or constructing one from environment/injected closures — see Step 3) — presented by `SiteWindow.swift` (Task 12).

- [ ] **Step 1: Rename the file and its types**

```bash
git mv Sources/AnglesiteApp/AnimationsGalleryView.swift Sources/AnglesiteApp/EffectsGalleryView.swift
```

- [ ] **Step 2: Rewrite with two-section grouping**

Replace the file's contents. Rename every `Animation*` identifier to `Effect*` (`AnimationsGalleryModel`→`EffectsGalleryModel`, `AnimationCatalog`→`EffectCatalog`, `AnimationCatalogEntry`→`EffectCatalogEntry`, `AnimationCategory`→`EffectCategory`, `AnimationsGalleryView`→`EffectsGalleryView`, `AnimationDetailView`→`EffectDetailView`, `AnimationDemoWebView`→`EffectDemoWebView`), and:

- Split the sidebar's `ForEach(EffectCategory.allCases, ...)` into two `Section` groups — `Section("Micro-interactions")` wrapping `[.text, .cards, .buttons, .backgrounds, .navigation]` and `Section("Visual effects")` wrapping `[.canvasBackground, .cursorReactive, .scrollDriven, .generativeArt]` — each still rendering one inner `Section(category.displayName)` per non-empty category (nested sections; if `List` disallows nested `Section`, use a flat `Section` per category but order the array so the two groups stay visually contiguous, and add a one-line `Text` group header row above each group's first category instead — pick whichever renders correctly when you build, and note the choice in the commit message).
- Extend `EffectCategory.displayName` with the four new cases: `.canvasBackground: "Canvas Backgrounds"`, `.cursorReactive: "Cursor-Reactive"`, `.scrollDriven: "Scroll-Driven"`, `.generativeArt: "Generative Art"`.
- In `EffectDetailView`, add an `EffectPlacementController` `@Bindable var controller: EffectPlacementController` property and, when `entry.placement != nil`, an **"Apply to page…"** button next to "Copy Snippet" calling `controller.startPlacement(for: entry, enterOverlayMode:, exitOverlayMode:)` (the two closures are passed in from whatever owns the live preview's `WKWebView` — thread them as init parameters on `EffectsGalleryView`/`EffectsGalleryModel`, same as `demoURL` is threaded today).
- Add a small HUD overlay (a `ZStack` over `content`, shown when `controller.state` is `.picking`/`.applying`/`.failed`) reading "Click where to place this effect" with a "Cancel" button calling `controller.cancel()`, an Esc key handler (`.onExitCommand { controller.cancel() }` on the sheet), and a transient success/failure banner for `.succeeded`/`.failed` before returning to `.idle`.
- `navigationTitle("Animations")` → `navigationTitle("Effects")`; `ContentUnavailableView("Animations Unavailable", ...)` → `"Effects Unavailable"`.

Because this task is UI-heavy and best verified visually, there is no new automated test here beyond what Task 10 already covers (the controller driving the HUD state) — verify manually per the Manual Verification section at the end of this plan.

- [ ] **Step 3: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean. Fix any leftover `Animation*` reference the rename missed (the compiler will point at each one).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/EffectsGalleryView.swift
git commit -m "feat(#768): rename AnimationsGalleryView to EffectsGalleryView, add apply flow"
```

---

### Task 12: Rewire `SiteWindowModel`/`WebsiteCommands`/`SiteWindow` for the rename + new wiring

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/WebsiteCommands.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `EffectPlacementController` (Task 10), `PageModelClient` (Task 4), `BlockManifestSync` (Task 8), `preview.editRouter`/`preview.mcpClient()` (existing, same accessors `makeComponentEditorContext` already uses).
- Produces: `SiteWindowModel.effectsPresented: Bool`, `canOpenEffects: Bool`, `presentEffects()`, `effectPlacementController: EffectPlacementController` (constructed once per site, alongside the existing `ComponentModelClient` construction).

- [ ] **Step 1: Rename in `SiteWindowModel.swift`**

Rename `animationsPresented`→`effectsPresented` (find its `@ObservationIgnored`/`private(set)` declaration near line 626-633 and its every other reference in the file — `grep -n animationsPresented Sources/AnglesiteApp/SiteWindowModel.swift` first to find them all), `canOpenAnimations`→`canOpenEffects`, `presentAnimations()`→`presentEffects()`. Update their doc comments' `#1007`/"Animations…" references to `#768`/"Effects…".

- [ ] **Step 2: Wire `PageModelClient` + `EffectPlacementController` + `BlockManifestSync`**

Near `makeComponentEditorContext(site:)` (which already builds `ComponentModelClient(mcpClient: { [preview] in await preview.mcpClient() })`), add:

```swift
    /// Builds the click-to-place controller for the Effects gallery. Mirrors
    /// `makeComponentEditorContext`'s `editRouter: preview.editRouter` reuse — placements apply
    /// through the same registered router the preview/Component Editor canvases use.
    private func makeEffectPlacementController(site: SiteStore.Site) -> EffectPlacementController {
        EffectPlacementController(
            path: preview.activeRoute ?? "/",
            pageModelClient: PageModelClient(mcpClient: { [preview] in await preview.mcpClient() }),
            editRouter: preview.editRouter
        )
    }
```

(Wire this constructor call the same way `makeComponentEditorContext` is called from wherever the site's context gets (re)built — check that call site and add the analogous one, storing the result in a new `effectPlacementController: EffectPlacementController?` property.)

Add a `blocks.manifest.json` sync call to wherever the site's template resolution already happens once per site-open (search for where `TemplateRuntime.resolve()` is called during site load — likely near `makeComponentEditorContext` or an earlier site-attach step):

```swift
    /// Ensures the site's `blocks.manifest.json` has entries for every shipped placeable effect.
    /// Fire-and-forget-safe (idempotent, cheap JSON merge) — called once per site attach, not on
    /// every gallery open.
    private func syncBlockManifest(site: SiteStore.Site) {
        guard let templateDirectory = TemplateRuntime.resolve().url else { return }
        let templateManifest = templateDirectory.appendingPathComponent("blocks.manifest.json")
        let siteManifest = site.sourceDirectory.appendingPathComponent("blocks.manifest.json")
        try? BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)
    }
```

Call `syncBlockManifest(site:)` from the same place the site's other one-time-per-open setup already runs (find where `SiteStore.Site` first becomes available in this file — likely a `didSet` on the `site` property, or an early step in whatever function first constructs `makeComponentEditorContext`).

- [ ] **Step 3: Rename in `WebsiteCommands.swift`**

```swift
Button("Effects…") { model?.presentEffects() }
    .disabled(model?.canOpenEffects != true)
```

- [ ] **Step 4: Rename in `SiteWindow.swift`**

Update the `.sheet(isPresented: $model.animationsPresented)`-shaped binding (find it near the `AnimationsGalleryView()` reference) to `$model.effectsPresented`, and `AnimationsGalleryView()` → `EffectsGalleryView(controller: model.effectPlacementController, enterOverlayMode:, exitOverlayMode:)` — threading the overlay-mode closures through to whatever already owns the `WKWebView`/`PreviewModel` reference at that call site (likely `PreviewModel` already exposes an `evaluateJavaScript`-style hook; call `window.anglesite._enterPlacementMode()` / `_exitPlacementMode()` through it, mirroring however existing JS-bridge calls from Swift are made elsewhere in this file — grep for an existing `evaluateJavaScript` call site to match the pattern exactly).

- [ ] **Step 5: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/WebsiteCommands.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#768): wire EffectPlacementController and blocks.manifest sync into SiteWindow"
```

---

### Task 13: `AddEffectIntent` (App Intent)

**Files:**
- Create: `Sources/AnglesiteIntents/EffectIntents.swift`
- Test: `Tests/AnglesiteIntentsTests/EffectIntentsTests.swift`

**Interfaces:**
- Consumes: `EffectCatalog`/`EffectCatalogEntry` (Task 1), the existing `AddStoreIntent` router pattern (`Sources/AnglesiteIntents/IntegrationIntents.swift`) as a structural template only (read it before writing this task, don't copy verbatim — its `Answers`/`applyIntegration` helpers are integration-specific).
- Produces: `struct AddEffectIntent: AppIntent` with `@Parameter var effect: EffectAppEnum` and `@Parameter var site: SiteEntity` (or whatever site-selection parameter type `IntegrationIntents.swift`'s intents already use — match it exactly), planning placement via `entry.placement.kind` defaults (no click available from Siri): `.background` → last child of `<body>` (index = body's child count); `.inline` → first child matching `allowedParents`, or the fragment root if unconstrained.

- [ ] **Step 1: Read the existing pattern**

Before writing any code, read `Sources/AnglesiteIntents/IntegrationIntents.swift` in full and note: (a) the exact site-parameter type and how an intent resolves it to a `SiteStore.Site`, (b) how `AddStoreIntent` plans before confirming (so a missing/ambiguous case reprompts rather than false-confirms), (c) the `IntegrationDialogs.applied`/`.failed` pattern for the final `.result(dialog:)`.

- [ ] **Step 2: Write the failing test**

```swift
// Tests/AnglesiteIntentsTests/EffectIntentsTests.swift
import Testing
@testable import AnglesiteIntents
@testable import AnglesiteCore

@Suite struct EffectIntentsTests {
    @Test func backgroundPlacementDefaultsToEndOfBody() {
        let entry = EffectCatalogEntry(
            component: "ParticleField", title: "Particle Field", ownerDescription: "d",
            category: .canvasBackground, keyProps: [:], snippet: "s",
            placement: .init(kind: .background, allowedParents: nil))
        let model = PageModelTests.fixtureModelWithBody() // reuse or add a small shared fixture; see note below
        let insertion = AddEffectIntent.defaultInsertion(for: entry, in: model)
        #expect(insertion?.parentId == model.tree.children.first?.id)
    }
}
```

Note: add a minimal `fixtureModelWithBody()` static helper (same shape as `PlacementMatcherTests.fixtureModel()` from Task 7 — a `<body>` with a couple of element children) either in a small shared test-support file or duplicated locally; do not import `AnglesiteCoreTests` from `AnglesiteIntentsTests` (test targets don't depend on each other).

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path . --filter EffectIntentsTests`
Expected: FAIL — `AddEffectIntent`/`defaultInsertion` don't exist.

- [ ] **Step 4: Write the implementation**

```swift
// Sources/AnglesiteIntents/EffectIntents.swift
import AppIntents
import AnglesiteCore

/// Adds a catalog effect to a site via Siri/Shortcuts, mirroring `AddStoreIntent`'s router
/// pattern (plan before confirm, so a missing/ambiguous placement reprompts rather than false-
/// confirming). No live-preview click is available from this front door, so placement is
/// computed deterministically from `entry.placement.kind` via `defaultInsertion`.
public struct AddEffectIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add Effect"
    public static var description = IntentDescription("Add a visual effect to a page on your site.")

    @Parameter(title: "Effect")
    public var effect: EffectAppEnum

    public init() {}

    /// Computes a default `{parentId, index}` for an effect with no click to resolve against.
    /// `.background` inserts as the last child of `<body>` (or the tree root if no `<body>` is
    /// found — an unusual page, but insertion should still succeed rather than refuse).
    /// `.inline` inserts as the first child of the first node matching `allowedParents` (or the
    /// tree root when `allowedParents` is nil).
    public static func defaultInsertion(for entry: EffectCatalogEntry, in model: PageModel) -> PlacementMatcher.Insertion? {
        guard let placement = entry.placement else { return nil }
        switch placement.kind {
        case .background:
            let body = findNode(tagged: "BODY", in: model.tree) ?? model.tree
            return PlacementMatcher.Insertion(parentId: body.id, index: body.children.count)
        case .inline:
            if let allowedParents = placement.allowedParents,
               let match = allowedParents.lazy.compactMap({ findNode(tagged: $0, in: model.tree) }).first {
                return PlacementMatcher.Insertion(parentId: match.id, index: 0)
            }
            return PlacementMatcher.Insertion(parentId: model.tree.id, index: model.tree.children.count)
        }
    }

    private static func findNode(tagged tag: String, in node: PageModel.Node) -> PageModel.Node? {
        if node.tag?.uppercased() == tag.uppercased() { return node }
        for child in node.children {
            if let found = findNode(tagged: tag, in: child) { return found }
        }
        return nil
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Full apply wiring (site resolution, get_page_model fetch, insertBlock apply,
        // IntegrationDialogs-style success/failure dialog) follows IntegrationIntents.swift's
        // AddStoreIntent shape exactly — implement by mirroring that file's perform() body,
        // substituting PageModelClient.fetch + defaultInsertion + insertBlock for its
        // plan/apply calls.
        .result(dialog: "Added \(effect.rawValue) to your site.")
    }
}

/// `AppEnum` over the catalog's placeable effect ids, for Siri's parameter picker.
public enum EffectAppEnum: String, AppEnum {
    case particleField = "Particle Field"
    case auroraGradient = "Aurora Gradient"
    case grainOverlay = "Grain Overlay"
    case magneticButton = "Magnetic Button"
    case cursorGlow = "Cursor Glow"
    case tiltCard = "Tilt Card"
    case parallaxLayers = "Parallax Layers"
    case revealMask = "Reveal Mask"
    case scrollProgressTrace = "Scroll Progress Trace"
    case blobMorph = "Blob Morph"
    case meshGradient = "Mesh Gradient"
    case dotGridPulse = "Dot Grid Pulse"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Effect"
    public static var caseDisplayRepresentations: [EffectAppEnum: DisplayRepresentation] = [
        .particleField: "Particle Field", .auroraGradient: "Aurora Gradient", .grainOverlay: "Grain Overlay",
        .magneticButton: "Magnetic Button", .cursorGlow: "Cursor Glow", .tiltCard: "Tilt Card",
        .parallaxLayers: "Parallax Layers", .revealMask: "Reveal Mask", .scrollProgressTrace: "Scroll Progress Trace",
        .blobMorph: "Blob Morph", .meshGradient: "Mesh Gradient", .dotGridPulse: "Dot Grid Pulse",
    ]
}
```

`perform()`'s body is intentionally left as a documented follow-up wiring step (site resolution + `PageModelClient` + `MCPApplyEditRouter` + confirmation dialog) rather than fully inlined here — completing it means reading `IntegrationIntents.swift`'s actual site-parameter/confirmation types (Step 1) and matching them exactly, which this plan cannot see ahead of time. Implement it during this task using Step 1's notes before moving on; do not leave the placeholder `.result(dialog:)` in the merged code.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path . --filter EffectIntentsTests`
Expected: PASS (the `defaultInsertion` unit test doesn't depend on `perform()` being finished)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteIntents/EffectIntents.swift Tests/AnglesiteIntentsTests/EffectIntentsTests.swift
git commit -m "feat(#768): add AddEffectIntent"
```

---

### Task 14: Canvas-background effects (ParticleField, AuroraGradient, GrainOverlay)

**Files:**
- Create: `Resources/Template/src/components/effects/ParticleField.astro`
- Create: `Resources/Template/src/components/effects/AuroraGradient.astro`
- Create: `Resources/Template/src/components/effects/GrainOverlay.astro`
- Modify: `Resources/Template/integrations/effects.json` (append 3 entries)
- Modify: `Resources/Template/blocks.manifest.json` (append 3 modules)

**Interfaces:**
- Produces: three `.astro` components, each `<div class="…-root" data-…>` full-bleed, `position: absolute; inset: 0; z-index: -1` (background layer, expects a `position: relative` ancestor — note this requirement in each component's doc comment), each with a plain (non-`is:inline`) `<script>` gated by `IntersectionObserver` and `prefers-reduced-motion`.

- [ ] **Step 1: `ParticleField.astro`**

```astro
---
/**
 * Effects gallery — Canvas Backgrounds (#768). Drifting particles with faint connecting lines
 * when close. Full-bleed background layer: place inside a `position: relative` (or `static`
 * with a stacking context) ancestor — it positions itself `absolute; inset: 0`.
 */
interface Props {
  density?: number;
  color?: string;
}
const { density = 60, color = "currentColor" } = Astro.props;
---
<div class="particle-field-root" data-density={density} data-color={color}>
  <canvas></canvas>
</div>

<script>
  class ParticleField {
    constructor(root: HTMLElement) {
      const canvas = root.querySelector("canvas") as HTMLCanvasElement;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      const density = Number(root.dataset.density ?? 60);
      const color = root.dataset.color ?? "currentColor";
      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

      let particles: { x: number; y: number; vx: number; vy: number }[] = [];
      let raf = 0;
      let running = false;

      function resize() {
        canvas.width = root.clientWidth;
        canvas.height = root.clientHeight;
        particles = Array.from({ length: density }, () => ({
          x: Math.random() * canvas.width,
          y: Math.random() * canvas.height,
          vx: (Math.random() - 0.5) * 0.3,
          vy: (Math.random() - 0.5) * 0.3,
        }));
      }

      function drawStaticFrame() {
        resize();
        if (!ctx) return;
        ctx.fillStyle = color;
        for (const p of particles) ctx.fillRect(p.x, p.y, 1.5, 1.5);
      }

      function tick() {
        if (!running || !ctx) return;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = color;
        for (const p of particles) {
          p.x += p.vx;
          p.y += p.vy;
          if (p.x < 0 || p.x > canvas.width) p.vx *= -1;
          if (p.y < 0 || p.y > canvas.height) p.vy *= -1;
          ctx.beginPath();
          ctx.arc(p.x, p.y, 1.5, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.strokeStyle = color;
        ctx.globalAlpha = 0.15;
        for (let i = 0; i < particles.length; i++) {
          for (let j = i + 1; j < particles.length; j++) {
            const dx = particles[i].x - particles[j].x;
            const dy = particles[i].y - particles[j].y;
            if (dx * dx + dy * dy < 80 * 80) {
              ctx.beginPath();
              ctx.moveTo(particles[i].x, particles[i].y);
              ctx.lineTo(particles[j].x, particles[j].y);
              ctx.stroke();
            }
          }
        }
        ctx.globalAlpha = 1;
        raf = requestAnimationFrame(tick);
      }

      if (reduceMotion) {
        drawStaticFrame();
      } else {
        const observer = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting && !running) {
              running = true;
              resize();
              raf = requestAnimationFrame(tick);
            } else if (!entry.isIntersecting && running) {
              running = false;
              cancelAnimationFrame(raf);
            }
          }
        });
        observer.observe(root);
        addEventListener("resize", resize, { passive: true });
      }
    }
  }

  document.querySelectorAll<HTMLElement>(".particle-field-root").forEach((el) => new ParticleField(el));
</script>

<style>
  .particle-field-root {
    position: absolute;
    inset: 0;
    z-index: -1;
    overflow: hidden;
    pointer-events: none;
  }
  .particle-field-root canvas {
    width: 100%;
    height: 100%;
    display: block;
  }
</style>
```

- [ ] **Step 2: `AuroraGradient.astro`**

```astro
---
/**
 * Effects gallery — Canvas Backgrounds (#768). Slow, blurred color-blob blending. Full-bleed
 * background layer: place inside a `position: relative` ancestor.
 */
interface Props {
  colors?: string[];
}
const { colors = ["#7c3aed", "#2563eb", "#0891b2"] } = Astro.props;
---
<div class="aurora-gradient-root" data-colors={colors.join(",")}>
  <canvas></canvas>
</div>

<script>
  class AuroraGradient {
    constructor(root: HTMLElement) {
      const canvas = root.querySelector("canvas") as HTMLCanvasElement;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      const colors = (root.dataset.colors ?? "").split(",").filter(Boolean);
      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
      let raf = 0;
      let running = false;
      let t = 0;

      function resize() {
        canvas.width = root.clientWidth;
        canvas.height = root.clientHeight;
      }

      function paint(time: number) {
        if (!ctx) return;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        colors.forEach((color, i) => {
          const angle = time + (i * Math.PI * 2) / colors.length;
          const x = canvas.width / 2 + Math.cos(angle) * canvas.width * 0.3;
          const y = canvas.height / 2 + Math.sin(angle) * canvas.height * 0.3;
          const gradient = ctx.createRadialGradient(x, y, 0, x, y, Math.max(canvas.width, canvas.height) * 0.4);
          gradient.addColorStop(0, color);
          gradient.addColorStop(1, "transparent");
          ctx.fillStyle = gradient;
          ctx.globalAlpha = 0.5;
          ctx.fillRect(0, 0, canvas.width, canvas.height);
        });
        ctx.globalAlpha = 1;
      }

      function tick() {
        if (!running) return;
        t += 0.002;
        paint(t);
        raf = requestAnimationFrame(tick);
      }

      resize();
      if (reduceMotion) {
        paint(0);
      } else {
        const observer = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting && !running) {
              running = true;
              raf = requestAnimationFrame(tick);
            } else if (!entry.isIntersecting && running) {
              running = false;
              cancelAnimationFrame(raf);
            }
          }
        });
        observer.observe(root);
        addEventListener("resize", resize, { passive: true });
      }
    }
  }

  document.querySelectorAll<HTMLElement>(".aurora-gradient-root").forEach((el) => new AuroraGradient(el));
</script>

<style>
  .aurora-gradient-root {
    position: absolute;
    inset: 0;
    z-index: -1;
    overflow: hidden;
    pointer-events: none;
    filter: blur(40px);
  }
  .aurora-gradient-root canvas {
    width: 100%;
    height: 100%;
    display: block;
  }
</style>
```

- [ ] **Step 3: `GrainOverlay.astro`**

```astro
---
/**
 * Effects gallery — Canvas Backgrounds (#768). Subtle animated film-grain texture. Full-bleed
 * background layer: place inside a `position: relative` ancestor.
 */
interface Props {
  opacity?: number;
}
const { opacity = 0.05 } = Astro.props;
---
<div class="grain-overlay-root" data-opacity={opacity}>
  <canvas></canvas>
</div>

<script>
  class GrainOverlay {
    constructor(root: HTMLElement) {
      const canvas = root.querySelector("canvas") as HTMLCanvasElement;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      const opacity = Number(root.dataset.opacity ?? 0.05);
      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
      let raf = 0;
      let running = false;
      let lastFrame = 0;

      function resize() {
        canvas.width = root.clientWidth;
        canvas.height = root.clientHeight;
      }

      function paintNoise() {
        if (!ctx) return;
        const imageData = ctx.createImageData(canvas.width, canvas.height);
        const buffer = imageData.data;
        for (let i = 0; i < buffer.length; i += 4) {
          const shade = Math.random() * 255;
          buffer[i] = buffer[i + 1] = buffer[i + 2] = shade;
          buffer[i + 3] = opacity * 255;
        }
        ctx.putImageData(imageData, 0, 0);
      }

      function tick(time: number) {
        if (!running) return;
        // Throttle to ~12fps — grain reads as motion even at a low frame rate, and this keeps
        // CPU cost far below a full 60fps canvas redraw.
        if (time - lastFrame > 83) {
          lastFrame = time;
          paintNoise();
        }
        raf = requestAnimationFrame(tick);
      }

      resize();
      if (reduceMotion) {
        paintNoise();
      } else {
        const observer = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting && !running) {
              running = true;
              raf = requestAnimationFrame(tick);
            } else if (!entry.isIntersecting && running) {
              running = false;
              cancelAnimationFrame(raf);
            }
          }
        });
        observer.observe(root);
        addEventListener("resize", resize, { passive: true });
      }
    }
  }

  document.querySelectorAll<HTMLElement>(".grain-overlay-root").forEach((el) => new GrainOverlay(el));
</script>

<style>
  .grain-overlay-root {
    position: absolute;
    inset: 0;
    z-index: -1;
    overflow: hidden;
    pointer-events: none;
    mix-blend-mode: overlay;
  }
  .grain-overlay-root canvas {
    width: 100%;
    height: 100%;
    display: block;
  }
</style>
```

- [ ] **Step 4: Append catalog entries to `effects.json`**

Add to the `components` array:

```json
{
  "component": "ParticleField",
  "title": "Particle Field",
  "ownerDescription": "Drifting dots connected by faint lines when close.",
  "category": "canvasBackground",
  "keyProps": { "density": "particle count (default 60)", "color": "dot/line color (default currentColor)" },
  "props": { "density": 60, "color": "#7c3aed" },
  "snippet": "---\nimport ParticleField from \"../components/effects/ParticleField.astro\";\n---\n<div style=\"position: relative;\">\n  <ParticleField />\n</div>",
  "placement": { "kind": "background", "allowedParents": null }
},
{
  "component": "AuroraGradient",
  "title": "Aurora Gradient",
  "ownerDescription": "Slow blurred color-blob blending.",
  "category": "canvasBackground",
  "keyProps": { "colors": "array of CSS colors (default a purple/blue/teal trio)" },
  "props": { "colors": ["#7c3aed", "#2563eb", "#0891b2"] },
  "snippet": "---\nimport AuroraGradient from \"../components/effects/AuroraGradient.astro\";\n---\n<div style=\"position: relative;\">\n  <AuroraGradient />\n</div>",
  "placement": { "kind": "background", "allowedParents": null }
},
{
  "component": "GrainOverlay",
  "title": "Grain Overlay",
  "ownerDescription": "Subtle animated film-grain texture.",
  "category": "canvasBackground",
  "keyProps": { "opacity": "0-1 (default 0.05)" },
  "props": { "opacity": 0.05 },
  "snippet": "---\nimport GrainOverlay from \"../components/effects/GrainOverlay.astro\";\n---\n<div style=\"position: relative;\">\n  <GrainOverlay />\n</div>",
  "placement": { "kind": "background", "allowedParents": null }
}
```

- [ ] **Step 5: Append `blocks.manifest.json` modules**

```json
{
  "path": "src/components/effects/ParticleField.astro",
  "export": "ParticleField",
  "kind": "astro",
  "name": "Particle Field",
  "description": "Drifting dots connected by faint lines when close.",
  "icon": null,
  "propEditors": [],
  "slots": [],
  "placement": { "allowedParents": null }
},
{
  "path": "src/components/effects/AuroraGradient.astro",
  "export": "AuroraGradient",
  "kind": "astro",
  "name": "Aurora Gradient",
  "description": "Slow blurred color-blob blending.",
  "icon": null,
  "propEditors": [],
  "slots": [],
  "placement": { "allowedParents": null }
},
{
  "path": "src/components/effects/GrainOverlay.astro",
  "export": "GrainOverlay",
  "kind": "astro",
  "name": "Grain Overlay",
  "description": "Subtle animated film-grain texture.",
  "icon": null,
  "propEditors": [],
  "slots": [],
  "placement": { "allowedParents": null }
}
```

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/components/effects/ParticleField.astro Resources/Template/src/components/effects/AuroraGradient.astro \
        Resources/Template/src/components/effects/GrainOverlay.astro Resources/Template/integrations/effects.json Resources/Template/blocks.manifest.json
git commit -m "feat(#768): add canvas-background effects (ParticleField, AuroraGradient, GrainOverlay)"
```

(Full render/reduced-motion/consistency verification for all 12 new components happens together in Task 18 — this task and Tasks 15-17 just author the components and register them.)

---

### Task 15: Cursor-reactive effects (MagneticButton, CursorGlow, TiltCard)

**Files:**
- Create: `Resources/Template/src/components/effects/MagneticButton.astro`
- Create: `Resources/Template/src/components/effects/CursorGlow.astro`
- Create: `Resources/Template/src/components/effects/TiltCard.astro`
- Modify: `Resources/Template/integrations/effects.json` (append 3 entries, `category: "cursorReactive"`, `placement.kind: "inline"`)
- Modify: `Resources/Template/blocks.manifest.json` (append 3 modules)

Same step shape as Task 14 (write each component, append catalog + manifest entries, commit). Component behavior:

- [ ] **Step 1: `MagneticButton.astro`** — a real `<a>`/`<button>` (`href` prop selects the tag) that eases toward the pointer within a radius via `transform: translate()`, resetting on `pointerleave`. Gate the `pointermove` listener registration itself behind `matchMedia("(hover: hover) and (pointer: fine)").matches` (touch has no hover) rather than `IntersectionObserver` (it's a small interactive element, not an animation loop) — still respect `prefers-reduced-motion` by skipping the transform entirely (button stays static, still fully clickable) when reduced.

```astro
---
interface Props {
  text?: string;
  href?: string;
}
const { text = "Get in touch", href } = Astro.props;
const Tag = href ? "a" : "button";
---
<Tag class="magnetic-button" href={href}>{text}</Tag>

<script>
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const canHover = matchMedia("(hover: hover) and (pointer: fine)").matches;
  if (!reduceMotion && canHover) {
    document.querySelectorAll<HTMLElement>(".magnetic-button").forEach((el) => {
      const radius = 60;
      el.addEventListener("pointermove", (ev) => {
        const rect = el.getBoundingClientRect();
        const dx = ev.clientX - (rect.left + rect.width / 2);
        const dy = ev.clientY - (rect.top + rect.height / 2);
        const distance = Math.hypot(dx, dy);
        if (distance < radius) {
          el.style.transform = `translate(${dx * 0.3}px, ${dy * 0.3}px)`;
        }
      });
      el.addEventListener("pointerleave", () => {
        el.style.transform = "translate(0, 0)";
      });
    });
  }
</script>

<style>
  .magnetic-button {
    display: inline-block;
    padding: 0.75em 1.5em;
    border-radius: 999px;
    background: color-mix(in srgb, currentColor 10%, transparent);
    border: 1px solid currentColor;
    font: inherit;
    cursor: pointer;
    transition: transform 0.15s ease-out;
    text-decoration: none;
    color: inherit;
  }
</style>
```

- [ ] **Step 2: `CursorGlow.astro`** — a `position: fixed; inset: 0; pointer-events: none` full-viewport layer with a small radial-gradient div that follows the pointer with CSS-transition easing (no canvas needed — a single absolutely-positioned div is cheaper and simpler). Note in its doc comment: DOM insertion point doesn't affect its visual position (it's `position: fixed`), so `inline` placement here just means "add one instance somewhere in the page" — a second instance elsewhere would be redundant but harmless (the CSS class is idempotent per-instance, not page-singleton-enforced, since enforcing a page-wide singleton is out of scope for v1).

```astro
---
interface Props {
  color?: string;
}
const { color = "rgba(124, 58, 237, 0.35)" } = Astro.props;
---
<div class="cursor-glow-root" data-color={color}>
  <div class="cursor-glow-dot"></div>
</div>

<script>
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const canHover = matchMedia("(hover: hover) and (pointer: fine)").matches;
  if (!reduceMotion && canHover) {
    document.querySelectorAll<HTMLElement>(".cursor-glow-root").forEach((root) => {
      const dot = root.querySelector<HTMLElement>(".cursor-glow-dot");
      if (!dot) return;
      addEventListener("pointermove", (ev) => {
        dot.style.left = `${ev.clientX}px`;
        dot.style.top = `${ev.clientY}px`;
      }, { passive: true });
    });
  }
</script>

<style>
  .cursor-glow-root {
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 2147483646;
    overflow: hidden;
  }
  .cursor-glow-dot {
    position: fixed;
    width: 240px;
    height: 240px;
    border-radius: 50%;
    background: radial-gradient(circle, var(--cursor-glow-color, rgba(124, 58, 237, 0.35)), transparent 70%);
    transform: translate(-50%, -50%);
    transition: left 0.12s ease-out, top 0.12s ease-out;
  }
</style>

<script define:vars={{ color }} is:inline>
  document.currentScript?.previousElementSibling?.style.setProperty("--cursor-glow-color", color);
</script>
```

Note: the last `<script define:vars is:inline>` block only writes a literal color string into a CSS custom property (no dynamic logic, no third-party call, and its body is just one `setProperty` line templated at build time by Astro's `define:vars`, not owner/user input) — reconsider before shipping: **prefer moving this to the non-inline `<script>` above** by reading `data-color` off `root.dataset.color` the same way `MagneticButton`/others do, avoiding `is:inline` entirely for consistency with this plan's CSP stance. Do this substitution in Step 2 (remove the second `<script>` block, add `dot.style.setProperty("--cursor-glow-color", root.dataset.color ?? "rgba(124, 58, 237, 0.35)")` inside the first script, after `const dot = ...`) — the version above is shown only to flag the pitfall; implement the corrected version.

- [ ] **Step 3: `TiltCard.astro`** — a self-contained card (`title`, `body`, `imageSrc` props) with 3D tilt on pointer move within its bounds via `transform: perspective(600px) rotateX() rotateY()`.

```astro
---
interface Props {
  title?: string;
  body?: string;
  imageSrc?: string;
}
const { title = "Card title", body = "A short line of supporting copy.", imageSrc } = Astro.props;
---
<div class="tilt-card">
  {imageSrc && <img src={imageSrc} alt="" />}
  <h3>{title}</h3>
  <p>{body}</p>
</div>

<script>
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const canHover = matchMedia("(hover: hover) and (pointer: fine)").matches;
  if (!reduceMotion && canHover) {
    document.querySelectorAll<HTMLElement>(".tilt-card").forEach((card) => {
      card.addEventListener("pointermove", (ev) => {
        const rect = card.getBoundingClientRect();
        const px = (ev.clientX - rect.left) / rect.width - 0.5;
        const py = (ev.clientY - rect.top) / rect.height - 0.5;
        card.style.transform = `perspective(600px) rotateX(${py * -8}deg) rotateY(${px * 8}deg)`;
      });
      card.addEventListener("pointerleave", () => {
        card.style.transform = "perspective(600px) rotateX(0) rotateY(0)";
      });
    });
  }
</script>

<style>
  .tilt-card {
    display: block;
    max-width: 320px;
    padding: 1.5em;
    border-radius: 12px;
    background: color-mix(in srgb, currentColor 6%, transparent);
    border: 1px solid color-mix(in srgb, currentColor 15%, transparent);
    transition: transform 0.15s ease-out;
    transform-style: preserve-3d;
  }
  .tilt-card img {
    width: 100%;
    border-radius: 8px;
    margin-bottom: 0.75em;
  }
</style>
```

- [ ] **Step 4: Append `effects.json` entries** (category `cursorReactive`, `placement.kind: "inline"`, `allowedParents: null`) — same shape as Task 14 Step 4, one object per component, `snippet` importing from `../components/effects/<Name>.astro`.

- [ ] **Step 5: Append `blocks.manifest.json` modules** — same shape as Task 14 Step 5.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/components/effects/MagneticButton.astro Resources/Template/src/components/effects/CursorGlow.astro \
        Resources/Template/src/components/effects/TiltCard.astro Resources/Template/integrations/effects.json Resources/Template/blocks.manifest.json
git commit -m "feat(#768): add cursor-reactive effects (MagneticButton, CursorGlow, TiltCard)"
```

---

### Task 16: Scroll-driven effects (ParallaxLayers, RevealMask, ScrollProgressTrace)

**Files:**
- Create: `Resources/Template/src/components/effects/ParallaxLayers.astro`
- Create: `Resources/Template/src/components/effects/RevealMask.astro`
- Create: `Resources/Template/src/components/effects/ScrollProgressTrace.astro`
- Modify: `Resources/Template/integrations/effects.json` (append 3 entries, `category: "scrollDriven"`, `placement.kind: "inline"`)
- Modify: `Resources/Template/blocks.manifest.json` (append 3 modules)

- [ ] **Step 1: `ParallaxLayers.astro`** — two-layer decorative block, back layer moves slower than scroll via a scroll listener updating `transform: translateY()`, gated by `IntersectionObserver` (only listens to `scroll` while visible) and skipped entirely under reduced motion (layers render static).

```astro
---
interface Props {
  height?: string;
}
const { height = "40vh" } = Astro.props;
---
<div class="parallax-layers" style={`--parallax-height: ${height}`}>
  <div class="parallax-layer parallax-layer--back"></div>
  <div class="parallax-layer parallax-layer--front"></div>
</div>

<script>
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduceMotion) {
    document.querySelectorAll<HTMLElement>(".parallax-layers").forEach((root) => {
      const back = root.querySelector<HTMLElement>(".parallax-layer--back");
      if (!back) return;
      let listening = false;
      function onScroll() {
        const rect = root.getBoundingClientRect();
        back!.style.transform = `translateY(${rect.top * 0.15}px)`;
      }
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting && !listening) {
            listening = true;
            addEventListener("scroll", onScroll, { passive: true });
            onScroll();
          } else if (!entry.isIntersecting && listening) {
            listening = false;
            removeEventListener("scroll", onScroll);
          }
        }
      });
      observer.observe(root);
    });
  }
</script>

<style>
  .parallax-layers {
    position: relative;
    height: var(--parallax-height, 40vh);
    overflow: hidden;
    border-radius: 12px;
  }
  .parallax-layer {
    position: absolute;
    inset: -10% 0;
  }
  .parallax-layer--back {
    background: linear-gradient(180deg, color-mix(in srgb, currentColor 20%, transparent), transparent);
  }
  .parallax-layer--front {
    background: linear-gradient(0deg, color-mix(in srgb, currentColor 10%, transparent), transparent 60%);
  }
</style>
```

- [ ] **Step 2: `RevealMask.astro`** — a `<slot />`-wrapping content block that reveals via `clip-path` transition when scrolled into view (`IntersectionObserver`, one-shot — reveals once, doesn't re-hide on scroll back up). No motion at all under reduced motion (content just renders visible immediately).

```astro
---
---
<div class="reveal-mask">
  <slot>Sample content that reveals as you scroll.</slot>
</div>

<script>
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.querySelectorAll<HTMLElement>(".reveal-mask").forEach((el) => {
    if (reduceMotion) {
      el.classList.add("is-revealed");
      return;
    }
    const observer = new IntersectionObserver((entries, obs) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          el.classList.add("is-revealed");
          obs.unobserve(el);
        }
      }
    }, { threshold: 0.2 });
    observer.observe(el);
  });
</script>

<style>
  .reveal-mask {
    clip-path: inset(0 100% 0 0);
    transition: clip-path 0.6s ease-out;
  }
  .reveal-mask.is-revealed {
    clip-path: inset(0 0 0 0);
  }
</style>
```

- [ ] **Step 3: `ScrollProgressTrace.astro`** — a `position: fixed` canvas line that draws proportionally to page scroll percentage (a decorative reading-progress squiggle along one edge). Same "fixed, DOM position doesn't matter" note as `CursorGlow`.

```astro
---
interface Props {
  color?: string;
}
const { color = "currentColor" } = Astro.props;
---
<div class="scroll-progress-trace" data-color={color}>
  <canvas></canvas>
</div>

<script>
  class ScrollProgressTrace {
    constructor(root: HTMLElement) {
      const canvas = root.querySelector("canvas") as HTMLCanvasElement;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      const color = root.dataset.color ?? "currentColor";
      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

      function resize() {
        canvas.width = root.clientWidth;
        canvas.height = root.clientHeight;
      }

      function draw() {
        if (!ctx) return;
        const doc = document.documentElement;
        const max = doc.scrollHeight - doc.clientHeight;
        const progress = max > 0 ? Math.min(1, scrollY / max) : 0;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.strokeStyle = color;
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.moveTo(canvas.width / 2, 0);
        ctx.lineTo(canvas.width / 2, canvas.height * progress);
        ctx.stroke();
      }

      resize();
      draw();
      if (!reduceMotion) {
        addEventListener("scroll", draw, { passive: true });
        addEventListener("resize", () => { resize(); draw(); }, { passive: true });
      }
    }
  }

  document.querySelectorAll<HTMLElement>(".scroll-progress-trace").forEach((el) => new ScrollProgressTrace(el));
</script>

<style>
  .scroll-progress-trace {
    position: fixed;
    right: 12px;
    top: 0;
    width: 6px;
    height: 100vh;
    pointer-events: none;
    z-index: 2147483646;
  }
  .scroll-progress-trace canvas {
    width: 100%;
    height: 100%;
    display: block;
  }
</style>
```

- [ ] **Step 4: Append `effects.json` entries** (category `scrollDriven`, `placement.kind: "inline"`).

- [ ] **Step 5: Append `blocks.manifest.json` modules.**

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/components/effects/ParallaxLayers.astro Resources/Template/src/components/effects/RevealMask.astro \
        Resources/Template/src/components/effects/ScrollProgressTrace.astro Resources/Template/integrations/effects.json Resources/Template/blocks.manifest.json
git commit -m "feat(#768): add scroll-driven effects (ParallaxLayers, RevealMask, ScrollProgressTrace)"
```

---

### Task 17: Generative-art effects (BlobMorph, MeshGradient, DotGridPulse) — pure CSS/SVG, no JS

**Files:**
- Create: `Resources/Template/src/components/effects/BlobMorph.astro`
- Create: `Resources/Template/src/components/effects/MeshGradient.astro`
- Create: `Resources/Template/src/components/effects/DotGridPulse.astro`
- Modify: `Resources/Template/integrations/effects.json` (append 3 entries, `category: "generativeArt"`, `placement.kind: "inline"`)
- Modify: `Resources/Template/blocks.manifest.json` (append 3 modules)

- [ ] **Step 1: `BlobMorph.astro`**

```astro
---
interface Props {
  color?: string;
  size?: string;
}
const { color = "currentColor", size = "320px" } = Astro.props;
---
<div class="blob-morph" style={`--blob-color: ${color}; --blob-size: ${size}`}></div>

<style>
  .blob-morph {
    width: var(--blob-size, 320px);
    height: var(--blob-size, 320px);
    background: color-mix(in srgb, var(--blob-color, currentColor) 25%, transparent);
    animation: blob-morph-shift 12s ease-in-out infinite;
  }
  @keyframes blob-morph-shift {
    0%, 100% { border-radius: 42% 58% 65% 35% / 45% 40% 60% 55%; }
    33% { border-radius: 60% 40% 30% 70% / 55% 65% 35% 45%; }
    66% { border-radius: 35% 65% 55% 45% / 40% 30% 70% 60%; }
  }
  @media (prefers-reduced-motion: reduce) {
    .blob-morph { animation: none; border-radius: 45% 55% 60% 40% / 50% 45% 55% 50%; }
  }
</style>
```

- [ ] **Step 2: `MeshGradient.astro`**

```astro
---
interface Props {
  colors?: string[];
}
const { colors = ["#7c3aed", "#2563eb", "#0891b2", "#db2777"] } = Astro.props;
---
<svg class="mesh-gradient" viewBox="0 0 400 400" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
  <defs>
    {colors.map((color, i) => (
      <radialGradient id={`mesh-gradient-${i}`} cx="50%" cy="50%" r="60%">
        <stop offset="0%" stop-color={color} stop-opacity="0.6" />
        <stop offset="100%" stop-color={color} stop-opacity="0" />
      </radialGradient>
    ))}
  </defs>
  {colors.map((_, i) => (
    <circle
      cx={80 + i * 90}
      cy={80 + ((i * 137) % 240)}
      r="180"
      fill={`url(#mesh-gradient-${i})`}
      class="mesh-gradient-blob"
      style={`--mesh-delay: ${i * -3}s`}
    />
  ))}
</svg>

<style>
  .mesh-gradient {
    width: 100%;
    height: 100%;
    display: block;
  }
  .mesh-gradient-blob {
    animation: mesh-gradient-drift 18s ease-in-out infinite;
    animation-delay: var(--mesh-delay, 0s);
    transform-origin: center;
  }
  @keyframes mesh-gradient-drift {
    0%, 100% { transform: translate(0, 0) scale(1); }
    50% { transform: translate(20px, -15px) scale(1.1); }
  }
  @media (prefers-reduced-motion: reduce) {
    .mesh-gradient-blob { animation: none; }
  }
</style>
```

- [ ] **Step 3: `DotGridPulse.astro`**

```astro
---
interface Props {
  columns?: number;
  rows?: number;
  color?: string;
}
const { columns = 8, rows = 4, color = "currentColor" } = Astro.props;
const dots = Array.from({ length: columns * rows }, (_, i) => i);
---
<div class="dot-grid-pulse" style={`--dgp-columns: ${columns}; --dgp-color: ${color}`}>
  {dots.map((i) => (
    <span class="dot-grid-pulse-dot" style={`--dgp-delay: ${(i % columns) * 0.1 + Math.floor(i / columns) * 0.1}s`}></span>
  ))}
</div>

<style>
  .dot-grid-pulse {
    display: grid;
    grid-template-columns: repeat(var(--dgp-columns, 8), 1fr);
    gap: 1em;
    padding: 1em;
  }
  .dot-grid-pulse-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--dgp-color, currentColor);
    animation: dot-grid-pulse-fade 2.4s ease-in-out infinite;
    animation-delay: var(--dgp-delay, 0s);
  }
  @keyframes dot-grid-pulse-fade {
    0%, 100% { opacity: 0.15; }
    50% { opacity: 1; }
  }
  @media (prefers-reduced-motion: reduce) {
    .dot-grid-pulse-dot { animation: none; opacity: 0.6; }
  }
</style>
```

- [ ] **Step 4: Append `effects.json` entries** (category `generativeArt`, `placement.kind: "inline"`, no `<script>` at all in any of the three — the consistency test in Task 18 asserts this specifically for this category).

- [ ] **Step 5: Append `blocks.manifest.json` modules.**

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/components/effects/BlobMorph.astro Resources/Template/src/components/effects/MeshGradient.astro \
        Resources/Template/src/components/effects/DotGridPulse.astro Resources/Template/integrations/effects.json Resources/Template/blocks.manifest.json
git commit -m "feat(#768): add generative-art effects (BlobMorph, MeshGradient, DotGridPulse)"
```

---

### Task 18: `effects-library.spec.ts` — render, snapshot, and consistency-check the 12 new effects

**Files:**
- Create: `Resources/Template/src/lib/effects-library.spec.ts`
- Modify: `Resources/Template/integrations/docs/effects.md` (document all 12 new components)

**Interfaces:**
- Consumes: `loadEffectsCatalog`/`placeableEntries` (Task 2), the 12 `.astro` files (Tasks 14-17), `Resources/Template/blocks.manifest.json` (Task 8's file, filled in by Tasks 14-17).
- Produces: `integrations/effects-demos/<component>.html` snapshot files for the 12 new entries (generated by this spec's `toMatchFileSnapshot`, same mechanism the legacy suite already uses — do not hand-author these).

- [ ] **Step 1: Write the spec**

```typescript
// Resources/Template/src/lib/effects-library.spec.ts
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { loadEffectsCatalog, placeableEntries } from "../../scripts/effects-catalog";

const catalog = loadEffectsCatalog();
const entries = placeableEntries(catalog);
const NO_SCRIPT_CATEGORIES = new Set(["generativeArt"]);

describe("effects library (new, placeable components)", () => {
  it("has exactly 12 placeable entries", () => {
    expect(entries.length).toBe(12);
  });

  it("every placeable entry has a matching blocks.manifest.json module", () => {
    const manifest = JSON.parse(readFileSync("blocks.manifest.json", "utf8")) as {
      modules: { path: string; name: string }[];
    };
    for (const entry of entries) {
      const expectedPath = `src/components/effects/${entry.component}.astro`;
      const module = manifest.modules.find((m) => m.path === expectedPath);
      expect(module, `${entry.component} missing from blocks.manifest.json`).toBeDefined();
      expect(module?.name).toBe(entry.title);
    }
  });

  it("generative-art components never emit a <script> tag", () => {
    for (const entry of entries.filter((e) => e.category === "generativeArt")) {
      const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
      expect(source, entry.component).not.toContain("<script");
    }
  });

  it("no component uses is:inline with a literal script body (CSP: script-src 'self')", () => {
    for (const entry of entries) {
      const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
      expect(source, entry.component).not.toMatch(/<script[^>]*\bis:inline\b/);
    }
  });

  for (const entry of entries) {
    describe(entry.component, () => {
      it("renders and, when animated, guards reduced motion", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const html = await container.renderToString(mod.default, { props: entry.props });
        expect(html.length).toBeGreaterThan(0);
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        if (!NO_SCRIPT_CATEGORIES.has(entry.category)) {
          expect(source, entry.component).toContain("prefers-reduced-motion");
        } else {
          expect(source, entry.component).toContain("@media (prefers-reduced-motion: reduce)");
        }
      });

      it("demo snapshot is fresh", async () => {
        const container = await AstroContainer.create();
        const mod = await import(/* @vite-ignore */ `../components/effects/${entry.component}.astro`);
        const inner = await container.renderToString(mod.default, { props: entry.props });
        const source = readFileSync(`src/components/effects/${entry.component}.astro`, "utf8");
        const css = [...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n");
        const scriptBlocks = [...source.matchAll(/<script(?![^>]*is:inline)[^>]*>([\s\S]*?)<\/script>/g)]
          .map((m) => m[1])
          .join("\n");
        const page = [
          "<!doctype html>",
          `<html lang="en"><head><meta charset="utf-8"><title>${entry.title}</title>`,
          "<style>body{margin:0;position:relative;min-height:100vh;display:grid;place-items:center;",
          "font-family:-apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;color-scheme:light dark}</style>",
          `<style>${css}</style>`,
          "</head><body>",
          inner,
          scriptBlocks ? `<script>${scriptBlocks}</script>` : "",
          "</body></html>",
          "",
        ].join("\n").replace(/\r\n/g, "\n");
        await expect(page).toMatchFileSnapshot(`../../integrations/effects-demos/${entry.component}.html`);
      });
    });
  }

  it("every placeable component is documented", () => {
    const docs = readFileSync("integrations/docs/effects.md", "utf8");
    for (const entry of entries) {
      expect(docs, entry.component).toContain(`## ${entry.component}`);
    }
  });
});
```

- [ ] **Step 2: Run once to generate the demo snapshots**

Run (from `Resources/Template/`): `npm test -- effects-library.spec.ts -u`
Expected: the "demo snapshot is fresh" cases write 12 new files under `integrations/effects-demos/`; every other case should already PASS (if any component fails "renders" or the script/reduced-motion assertions, fix that component's `.astro` file from Tasks 14-17 before proceeding — do not weaken the assertion).

- [ ] **Step 3: Re-run without `-u` to confirm the snapshots are now stable**

Run: `npm test -- effects-library.spec.ts`
Expected: PASS, including "demo snapshot is fresh" (no diff against the just-written files).

- [ ] **Step 4: Document the 12 new components**

Append to `Resources/Template/integrations/docs/effects.md` (matching the existing doc's per-component `## <Component>` section format used for the legacy 16 — read one existing section first to match its exact shape: heading, one-line description, props table, snippet) one section per new component, using each entry's `title`/`ownerDescription`/`keyProps`/`snippet` from `effects.json`.

- [ ] **Step 5: Run the full template test suite**

Run (from `Resources/Template/`): `npm test`
Expected: PASS — both `effects-catalog.spec.ts` (16 legacy) and `effects-library.spec.ts` (12 new) green, plus everything else unaffected by this PR.

- [ ] **Step 6: Run the Swift catalog test one more time against the now-28-entry manifest**

Run: `swift test --package-path . --filter EffectCatalogTests`
Expected: PASS — `loadsRealTemplateCatalog` now finds demo files for all 28 entries, `onlyNewCategoriesArePlaceable` confirms exactly the 12 new ones carry `placement`.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/src/lib/effects-library.spec.ts Resources/Template/integrations/effects-demos Resources/Template/integrations/docs/effects.md
git commit -m "test(#768): render, snapshot, and document the 12 new effects"
```

---

### Task 19: End-to-end `insertBlock` round trip

**Files:**
- Modify: `Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift` (or the sibling e2e file — check both `AppliesEditEndToEndTests.swift` and `MCPClientHTTPEndToEndTests.swift` for which already has a `.enabled(if:)`-gated suite that boots a real sidecar against a scratch site, and add to whichever fits; do not create a third parallel e2e harness)

**Interfaces:**
- Consumes: a live sidecar (via `ANGLESITE_PLUGIN_PATH`), `PageModelClient` (Task 4), `ComponentStructureEditBuilder.insertBlock` (Task 5), `MCPApplyEditRouter` (existing).

- [ ] **Step 1: Write the test**

Following the existing e2e suite's setup pattern exactly (scratch site fixture, sidecar boot, `MCPClient` connect — read the existing file's `@Suite`/setup code first and reuse its helpers rather than duplicating them), add:

```swift
    @Test func insertBlockRoundTrip() async throws {
        // Reuse this suite's existing scratch-site fixture (it should already have a
        // blocks.manifest.json + src/components/effects/ if the fixture is the real template;
        // if the fixture is a minimal synthetic site instead, add a single manifest entry +
        // placeholder component file to it here before this test, matching this plan's
        // BlockManifestSync/effects.json shapes).
        let pageModelClient = PageModelClient(mcpClient: { await self.mcpClient() })
        let model = try await pageModelClient.fetch(path: "src/pages/index.astro")
        let bodyId = /* locate the <body> node id the same way PlacementMatcher/AddEffectIntent do, or hardcode from the fixture's known structure */ model.tree.children.first?.id ?? model.tree.id

        let edit = ComponentStructureEditBuilder.insertBlock(
            id: "e2e-1", path: "src/pages/index.astro", baseVersion: model.version,
            parentId: bodyId, index: 0, manifestBlock: "<the fixture's registered block name>")
        let router = MCPApplyEditRouter(mcpClient: { await self.mcpClient() })
        let reply = await router.apply(edit)

        #expect(reply.status == .applied)

        // Re-fetch and confirm the new node actually landed.
        let after = try await pageModelClient.fetch(path: "src/pages/index.astro")
        #expect(after.version != model.version)
    }
```

Fill in the two bracketed placeholders using whatever the suite's actual scratch-site fixture already provides (its real body-node id / a real registered block name) — do not leave them as literal placeholder text in the committed test.

- [ ] **Step 2: Run gated**

Run: `ANGLESITE_PLUGIN_PATH=<sidecar checkout path> swift test --package-path . --filter insertBlockRoundTrip`
Expected: PASS when a sidecar checkout is available; SKIPPED (not failed) when `ANGLESITE_PLUGIN_PATH` is unset, per the suite's existing `.enabled(if:)` gating.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift
git commit -m "test(#768): add e2e insertBlock round trip"
```

---

## Manual Verification (after all tasks land)

1. `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, launch the app.
2. Open or create a site. **Website ▸ Effects…** — confirm the sidebar shows two groups (Micro-interactions / Visual effects), all 28 entries browse and preview correctly.
3. Pick a placeable effect (e.g. Particle Field), click **Apply to page…**, confirm the live preview shows a placement-pick affordance, click a target element, confirm the HUD reports success and the preview refreshes with the effect visible.
4. Cancel a placement mid-pick (Esc and the Cancel button) — confirm it cleanly returns to browsing with no partial edit applied.
5. Repeat step 3 for one effect per new category (canvasBackground/cursorReactive/scrollDriven/generativeArt) to confirm each `placement.kind` behaves as designed (`background` lands behind the clicked element's parent; `inline` lands adjacent).
6. Confirm `prefers-reduced-motion` (macOS System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion) freezes every applied effect to a static frame.
7. Run `uvx reuse lint` (or `pipx run reuse lint`) — new files should be covered by the existing blanket `REUSE.toml` annotation with no per-file header needed.

## Follow-ups (explicitly out of scope, do not do these as part of this plan)

- `AddEffectIntent.perform()`'s full body (Task 13) needs `IntegrationIntents.swift`'s exact site-parameter/confirmation-dialog types filled in during that task, not deferred further.
- The `wrapper` placement kind (spec non-goal) — not implemented.
- `BookingWidget.astro`'s possible inline-script CSP gap — separately flagged, not part of this PR.
