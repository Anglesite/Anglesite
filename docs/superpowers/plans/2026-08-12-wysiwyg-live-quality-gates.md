# WYSIWYG slice 5 — live quality gates — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After each applied WYSIWYG op, the host re-analyzes the page's block model for five categories of issue (contrast, alt text, heading order, link integrity, image weight) and streams findings to the engine as advisory chips anchored to blocks; heading-order and (this slice) no other category gets a one-tap apply.

**Architecture:** Five pure Swift checkers (`Sources/AnglesiteCore/WYSIWYG/QualityGates/`) run against the in-memory `BlockModel` — no build, no container round-trip. `WYSIWYGCanvasController` re-runs them after every applied op and pushes the full current finding set to a new TypeScript module (`quality-gates.ts`) that renders/diffs chips in the canvas and, on Apply, resubmits the fix through the ordinary ops pipeline.

**Tech Stack:** Swift 6.4 (`AnglesiteCore`, `AnglesiteApp`), TypeScript (`JS/wysiwyg-engine`), Swift Testing, Vitest, Playwright.

## Global Constraints

- Swift 6.4 / Xcode 27, Node ≥22 (from `JS/wysiwyg-engine/package.json`'s `engines` field) — match existing toolchain, no version bumps.
- No new dependencies (Swift package or npm) without separate explicit approval per `CONTRIBUTING.md` — every task below uses only what's already a dependency of `AnglesiteCore`/`AnglesiteApp`/`JS/wysiwyg-engine`.
- `JS/wysiwyg-engine` must keep passing `npm run lint` (oxlint), `npm run typecheck` (`tsc --noEmit`, strict + `noUncheckedIndexedAccess` + `noImplicitOverride` + `verbatimModuleSyntax`), and `npm test` (vitest) after every task.
- The Swift package must keep passing `swift test --package-path .` after every task.
- Finding messages must be phrased in owner consequences ("photos this big load slowly on phones"), never lint jargon — design doc §1/§6.
- Conventional commit subjects, ≤72 characters, referencing `#1226`.
- Design doc: `docs/superpowers/specs/2026-08-12-wysiwyg-live-quality-gates-design.md` — every task below cites the section it implements.

---

## Task 1: `WYSIWYGCanvasController` — multiple `onOpApplied` listeners

A single-closure `onOpApplied` property can only have one subscriber; `undoCoordinator` already owns it. Quality-gate re-analysis (Task 10) needs a second subscriber without silently replacing the undo registration — the failure mode a single closure has.

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift:57` (the `onOpApplied` property), `:75-90` (`init`, `submit`), `:279-285` (`sendOp` conformance)
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift:15,33,113`

**Interfaces:**
- Produces: `WYSIWYGCanvasController.addOpAppliedListener(_ listener: @escaping (Op, Op, BlockModel) -> Void)` — every later task that needs to observe applied ops (Task 10) calls this instead of assigning `onOpApplied`.

- [ ] **Step 1: Update the three existing tests to use the new API instead of assigning `onOpApplied`**

In `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`, replace each of the three occurrences:

Line 15: `controller.onOpApplied = { op, inverse, model in reported = (op, inverse, model) }` → `controller.addOpAppliedListener { op, inverse, model in reported = (op, inverse, model) }`

Line 33: `controller.onOpApplied = { _, _, _ in applied = true }` → `controller.addOpAppliedListener { _, _, _ in applied = true }`

Line 113: `controller.onOpApplied = { op, inverse, _ in reported = (op, inverse) }` → `controller.addOpAppliedListener { op, inverse, _ in reported = (op, inverse) }`

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `addOpAppliedListener` does not exist yet.

- [ ] **Step 3: Replace the single-closure property with a listener list**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`, replace:

```swift
    /// Fires after every successfully applied op, with its inverse — set at `init` time to feed
    /// `undoCoordinator`. Still overridable by tests/other callers that need their own hook,
    /// same seam as before Task 9.
    var onOpApplied: ((Op, Op, BlockModel) -> Void)?
```

with:

```swift
    /// Fires after every successfully applied op, with its inverse. Multiple listeners can coexist
    /// — `undoCoordinator`'s registration (added at `init`) and `QualityGateRunner`'s re-analysis
    /// trigger (added by `PreviewModel.enterEditMode`, Task 10) both need this without either
    /// silently overwriting the other, the failure mode a single-closure property would have.
    private var opAppliedListeners: [(Op, Op, BlockModel) -> Void] = []

    func addOpAppliedListener(_ listener: @escaping (Op, Op, BlockModel) -> Void) {
        opAppliedListeners.append(listener)
    }

    private func fireOpApplied(_ op: Op, _ inverse: Op, _ model: BlockModel) {
        for listener in opAppliedListeners { listener(op, inverse, model) }
    }
```

Replace the `init`:

```swift
    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        onOpApplied = { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
    }
```

with:

```swift
    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        addOpAppliedListener { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
    }
```

Replace the two `onOpApplied?(...)` call sites — in `submit(_:)`:

```swift
        if case .applied(let newModel) = result {
            onOpApplied?(op, WYSIWYGOpInverter.invert(op), newModel)
        }
```

becomes:

```swift
        if case .applied(let newModel) = result {
            fireOpApplied(op, WYSIWYGOpInverter.invert(op), newModel)
        }
```

and in the `WYSIWYGHostTransport` conformance's `sendOp(_:)`:

```swift
        if case .applied(let newModel) = result {
            onOpApplied?(envelope.op, WYSIWYGOpInverter.invert(envelope.op), newModel)
        }
```

becomes:

```swift
        if case .applied(let newModel) = result {
            fireOpApplied(envelope.op, WYSIWYGOpInverter.invert(envelope.op), newModel)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Expected: PASS, all existing tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "refactor(#1226): support multiple onOpApplied listeners"
```

---

## Task 2: `Finding`, `GateContext`, and `BlockModel.orderedBlocks`

Design doc §3: the shared types every checker (Tasks 3, 5–8) and the runner (Task 9) build on.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/Finding.swift`
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift`
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/BlockModelTraversal.swift`
- Test: `Tests/AnglesiteCoreTests/QualityGateFindingTests.swift`

**Interfaces:**
- Produces: `Finding` (`blockId`, `category: FindingCategory`, `severity: FindingSeverity`, `message: String`, `fix: Op?`, derived `id: String`), `FindingCategory` (`.contrast`, `.altText`, `.headingOrder`, `.linkIntegrity`, `.imageWeight`), `FindingSeverity` (`.advisory`, `.warning`), `GateContext` (`resolvedTokens: [String: String]`, `internalRoutes: Set<String>`, `assetRoot: URL`), `BlockModel.orderedBlocks: [BlockNode]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/QualityGateFindingTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Finding id derivation")
struct FindingTests {
    @Test("id is blockId::category without a discriminator")
    func idWithoutDiscriminator() {
        let finding = Finding(blockId: "b1", category: .altText, severity: .warning, message: "m")
        #expect(finding.id == "b1::altText")
    }

    @Test("id appends the discriminator when one block can carry multiple findings in a category")
    func idWithDiscriminator() {
        let finding = Finding(blockId: "b1", category: .linkIntegrity, discriminator: "run.0", severity: .warning, message: "m")
        #expect(finding.id == "b1::linkIntegrity::run.0")
    }
}

@Suite("BlockModel.orderedBlocks")
struct BlockModelTraversalTests {
    @Test("visits root blocks in rootIds order, then each block's slot children before its siblings")
    func documentOrder() {
        let child = BlockNode(id: "child", kind: .text, componentName: "span", props: [:], slots: [:], sourceSpan: [0, 0])
        let container = BlockNode(id: "container", kind: .astro, componentName: "Box", props: [:], slots: ["main": ["child"]], sourceSpan: [0, 0])
        let sibling = BlockNode(id: "sibling", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(
            path: "src/pages/index.astro", version: "v1", rootIds: ["container", "sibling"],
            blocks: ["container": container, "child": child, "sibling": sibling])

        #expect(model.orderedBlocks.map(\.id) == ["container", "child", "sibling"])
    }

    @Test("skips a block id that isn't in the blocks dictionary instead of crashing")
    func missingBlockIsSkipped() {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["ghost"], blocks: [:])
        #expect(model.orderedBlocks.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter QualityGateFindingTests`
Expected: FAIL — `Finding`, `FindingCategory`, `BlockModel.orderedBlocks` don't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/Finding.swift`:

```swift
import Foundation

public enum FindingCategory: String, Codable, Sendable {
    case contrast
    case altText
    case headingOrder
    case linkIntegrity
    case imageWeight
}

public enum FindingSeverity: String, Codable, Sendable {
    case advisory
    case warning
}

/// A live quality-gate finding (spec §6) — advisory, anchored to a block, phrased in owner
/// consequences. Wire-compatible with `JS/wysiwyg-engine/src/quality-gates.ts`'s `Finding`.
public struct Finding: Codable, Equatable, Sendable {
    public let id: String
    public let blockId: BlockId
    public let category: FindingCategory
    public let severity: FindingSeverity
    public let message: String
    public let fix: Op?

    /// `id` is derived, never passed in — "<blockId>::<category>", or with `discriminator` appended
    /// as "<blockId>::<category>::<discriminator>" when one block can carry more than one finding in
    /// the same category (e.g. two broken links in one rich-text block). Deriving it here rather
    /// than trusting each gate to build a matching string by hand is what keeps ids stable across
    /// re-analysis — the property the engine's keyed diff (design doc §3) depends on.
    public init(blockId: BlockId, category: FindingCategory, discriminator: String? = nil, severity: FindingSeverity, message: String, fix: Op? = nil) {
        self.id = discriminator.map { "\(blockId)::\(category.rawValue)::\($0)" } ?? "\(blockId)::\(category.rawValue)"
        self.blockId = blockId
        self.category = category
        self.severity = severity
        self.message = message
        self.fix = fix
    }
}
```

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift`:

```swift
import Foundation

/// What a quality-gate checker needs beyond the `BlockModel` itself (design doc §3). Constructed by
/// `GateContext.build(fromSourceDirectory:)` (Task 4) and set on `WYSIWYGCanvasController` (Task 10)
/// once per mount.
public struct GateContext: Sendable {
    /// CSS custom-property name (without the `--` prefix) -> value, e.g. "color-text" -> "#222222".
    /// Parsed from the site's `src/styles/global.css` by `ContrastGate.parseCSSCustomProperties`.
    public var resolvedTokens: [String: String]
    /// Site-relative route paths that resolve to a real page, e.g. "/blog/hello-world" — built by
    /// walking `src/pages/**`.
    public var internalRoutes: Set<String>
    /// The site's `public/` directory — where a `src`/`href` prop pointing at a leading-`/` path
    /// resolves to a file on disk.
    public var assetRoot: URL

    public init(resolvedTokens: [String: String], internalRoutes: Set<String>, assetRoot: URL) {
        self.resolvedTokens = resolvedTokens
        self.internalRoutes = internalRoutes
        self.assetRoot = assetRoot
    }
}
```

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/BlockModelTraversal.swift`:

```swift
import Foundation

extension BlockModel {
    /// All blocks in document order (pre-order: each block, then its slots' children in slot-name
    /// order, then each slot's children in list order) — the order heading-hierarchy validation
    /// needs (`HeadingOrderGate`, Task 6), and a convenient "all blocks" traversal for the other
    /// gates, where order doesn't matter. Guards against a cyclic slots graph with a visited set —
    /// that should never occur, but a checker looping the main thread on malformed data would be a
    /// worse failure than a merely incomplete result.
    public var orderedBlocks: [BlockNode] {
        var result: [BlockNode] = []
        var visited = Set<BlockId>()
        func visit(_ id: BlockId) {
            guard visited.insert(id).inserted, let node = blocks[id] else { return }
            result.append(node)
            for slotName in node.slots.keys.sorted() {
                for childId in node.slots[slotName] ?? [] { visit(childId) }
            }
        }
        for id in rootIds { visit(id) }
        return result
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter QualityGateFindingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/Finding.swift Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift Sources/AnglesiteCore/WYSIWYG/QualityGates/BlockModelTraversal.swift Tests/AnglesiteCoreTests/QualityGateFindingTests.swift
git commit -m "feat(#1226): add Finding, GateContext, and BlockModel traversal"
```

---

## Task 3: `ContrastGate`

Design doc §2/§3: WCAG contrast against the site's global design tokens, reusing `WCAGContrast.swift`.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/ContrastGate.swift`
- Test: `Tests/AnglesiteCoreTests/ContrastGateTests.swift`

**Interfaces:**
- Consumes: `WCAGContrast.meetsAA(fg:bg:)`, `WCAGContrast.contrastRatio(_:_:)` (`Sources/AnglesiteCore/WCAGContrast.swift`); `Finding`, `GateContext` (Task 2); `rootParentID` (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`).
- Produces: `ContrastGate.analyze(model:context:) throws -> [Finding]`, `ContrastGate.parseCSSCustomProperties(from:) -> [String: String]` — the latter consumed by `GateContext.build` (Task 4).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ContrastGateTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ContrastGate")
struct ContrastGateTests {
    @Test("flags a token pair below the 4.5:1 AA ratio")
    func flagsLowContrastPair() throws {
        let context = GateContext(resolvedTokens: ["color-text": "#777777", "color-background": "#888888"], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["\(rootParentID)::contrast::color-text"])
    }

    @Test("does not flag a token pair that meets AA")
    func doesNotFlagGoodContrast() throws {
        let context = GateContext(resolvedTokens: ["color-text": "#000000", "color-background": "#ffffff"], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("skips a pair when either token is missing from resolvedTokens")
    func skipsMissingTokens() throws {
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])

        let findings = try ContrastGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("parseCSSCustomProperties extracts --name: value pairs from arbitrary CSS text")
    func parsesCustomProperties() {
        let css = """
        :root {
          --color-text: #222222;
          --color-background: #ffffff;
        }
        .unrelated { color: red; }
        """

        let tokens = ContrastGate.parseCSSCustomProperties(from: css)

        #expect(tokens["color-text"] == "#222222")
        #expect(tokens["color-background"] == "#ffffff")
        #expect(tokens.count == 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ContrastGateTests`
Expected: FAIL — `ContrastGate` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/ContrastGate.swift`:

```swift
import Foundation

/// WCAG contrast checks against the site's global design tokens (spec §6) — not per-block, since
/// the block model carries component props, not resolved computed style (design doc §3). Findings
/// anchor to `rootParentID`: there is no single block a color-pair choice belongs to, so the chip
/// renders as a page-level advisory (`quality-gates.ts`'s anchoring falls back to a fixed tray
/// position when `computeHandleRect` finds no element for `rootParentID`).
public enum ContrastGate {
    private struct Pair {
        let foreground: String
        let background: String
        let label: String
    }

    private static let pairs: [Pair] = [
        Pair(foreground: "color-text", background: "color-background", label: "body text"),
        Pair(foreground: "color-text-muted", background: "color-background", label: "muted text"),
        Pair(foreground: "color-text", background: "color-surface", label: "text on surfaces"),
        Pair(foreground: "color-primary", background: "color-background", label: "links and buttons"),
        Pair(foreground: "color-accent", background: "color-background", label: "accented text"),
    ]

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for pair in pairs {
            guard let fg = context.resolvedTokens[pair.foreground],
                  let bg = context.resolvedTokens[pair.background]
            else { continue } // token not set for this theme — nothing to check
            guard !WCAGContrast.meetsAA(fg: fg, bg: bg) else { continue }
            let ratio = WCAGContrast.contrastRatio(fg, bg)
            findings.append(Finding(
                blockId: rootParentID,
                category: .contrast,
                discriminator: pair.foreground,
                severity: .warning,
                message: "\(pair.label.capitalized) is hard to read — its contrast ratio is \(String(format: "%.1f", ratio)):1, below the 4.5:1 most readers need."))
        }
        return findings
    }

    /// Parses `--name: value;` custom properties out of raw CSS text — the site's actual on-disk
    /// source of truth for its resolved tokens (design doc §3: there is no runtime token reader
    /// today, so this reads the same file the site itself renders from). Deliberately simple:
    /// matches `--token-name: value;` pairs anywhere in the text rather than parsing full CSS syntax
    /// or scoping to `:root` — `Resources/Template/src/styles/global.css` only ever declares custom
    /// properties at the top level, so a stricter parser would add complexity with no behavioral
    /// difference for the files this actually runs against.
    public static func parseCSSCustomProperties(from css: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"--([a-zA-Z0-9-]+)\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsrange = NSRange(css.startIndex..<css.endIndex, in: css)
        regex.enumerateMatches(in: css, range: nsrange) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: css), let valueRange = Range(match.range(at: 2), in: css) else { return }
            result[String(css[nameRange])] = css[valueRange].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter ContrastGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/ContrastGate.swift Tests/AnglesiteCoreTests/ContrastGateTests.swift
git commit -m "feat(#1226): add ContrastGate"
```

---

## Task 4: `GateContext.build(fromSourceDirectory:)`

Design doc §3: builds a `GateContext` from a site's `Source/` directory — parses `global.css`, walks `src/pages/**` for routes, points `assetRoot` at `public/`.

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift` (append an extension)
- Test: `Tests/AnglesiteCoreTests/GateContextBuildTests.swift`

**Interfaces:**
- Consumes: `ContrastGate.parseCSSCustomProperties(from:)` (Task 3).
- Produces: `GateContext.build(fromSourceDirectory: URL) -> GateContext` — consumed by `WYSIWYGCanvasController`/`PreviewModel` wiring (Task 10).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/GateContextBuildTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("GateContext.build(fromSourceDirectory:)")
struct GateContextBuildTests {
    @Test("parses tokens from src/styles/global.css and routes from src/pages")
    func buildsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        let pagesDir = root.appendingPathComponent("src/pages/blog")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ":root { --color-text: #111111; }".write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        try "---\ntitle: Home\n---\n".write(to: root.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)
        try "---\ntitle: Post\n---\n".write(to: pagesDir.appendingPathComponent("hello-world.md"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.resolvedTokens["color-text"] == "#111111")
        #expect(context.internalRoutes.contains("/"))
        #expect(context.internalRoutes.contains("/blog/hello-world"))
        #expect(context.assetRoot == root.appendingPathComponent("public"))
    }

    @Test("skips bracketed dynamic-route directories")
    func skipsDynamicRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dynamicDir = root.appendingPathComponent("src/pages/[collection]")
        try FileManager.default.createDirectory(at: dynamicDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\n---\n".write(to: dynamicDir.appendingPathComponent("[slug].astro"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.internalRoutes.isEmpty)
    }

    @Test("an unreadable global.css yields an empty token set instead of throwing")
    func missingCSSYieldsEmptyTokens() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) // never created

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.resolvedTokens.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter GateContextBuildTests`
Expected: FAIL — `GateContext.build` doesn't exist yet.

- [ ] **Step 3: Implement**

Append to `Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift`:

```swift
extension GateContext {
    /// Builds a `GateContext` by reading straight off `sourceDirectory` (a site's `Source/`, design
    /// doc §3): parses `src/styles/global.css` for design tokens, walks `src/pages/**` for internal
    /// routes, and points `assetRoot` at `public/`. Best-effort — a missing/unreadable `global.css`
    /// yields an empty token set (`ContrastGate` simply has nothing to check) rather than throwing,
    /// since a `GateContext` with partial data is still useful for the other four gates.
    public static func build(fromSourceDirectory sourceDirectory: URL) -> GateContext {
        let cssURL = sourceDirectory.appendingPathComponent("src/styles/global.css")
        let css = (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
        let tokens = ContrastGate.parseCSSCustomProperties(from: css)

        let pagesURL = sourceDirectory.appendingPathComponent("src/pages")
        let routes = Self.routes(underPagesDirectory: pagesURL)

        let assetRoot = sourceDirectory.appendingPathComponent("public")
        return GateContext(resolvedTokens: tokens, internalRoutes: routes, assetRoot: assetRoot)
    }

    /// Recursively lists `src/pages/**/*.{astro,md,mdx}` and turns each into the site-relative route
    /// it renders at — Astro's file-based routing convention: strip the extension, and an `index`
    /// file's route is its parent directory. `[collection]`-style dynamic routes (bracketed path
    /// segments) are skipped — resolving them needs the content collection they iterate, not just
    /// the filesystem, so a real page under one would false-positive as "no matching route" against
    /// this gate; the deploy-time backstop already covers dynamic routes.
    private static func routes(underPagesDirectory pagesURL: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: pagesURL, includingPropertiesForKeys: nil) else { return [] }
        var routes: Set<String> = []
        let pageExtensions: Set<String> = ["astro", "md", "mdx"]
        for case let fileURL as URL in enumerator {
            guard pageExtensions.contains(fileURL.pathExtension) else { continue }
            let relative = fileURL.path.replacingOccurrences(of: pagesURL.path, with: "")
            guard !relative.contains("[") else { continue } // dynamic route — see doc comment
            let ext = fileURL.pathExtension
            var route: String
            if relative.hasSuffix("/index.\(ext)") {
                route = String(relative.dropLast("index.\(ext)".count + 1))
            } else {
                route = String(relative.dropLast(ext.count + 1))
            }
            if route.isEmpty { route = "/" }
            routes.insert(route)
        }
        return routes
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter GateContextBuildTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/GateContext.swift Tests/AnglesiteCoreTests/GateContextBuildTests.swift
git commit -m "feat(#1226): build GateContext from a site's Source/ directory"
```

---

## Task 5: `AltTextGate`

Design doc §2: hand-ported from `a11y-validate.ts`'s `validateImageAlt`, operating on the typed `BlockModel` instead of parsed HTML.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/AltTextGate.swift`
- Test: `Tests/AnglesiteCoreTests/AltTextGateTests.swift`

**Interfaces:**
- Consumes: `BlockModel.orderedBlocks`, `Finding`, `GateContext` (Task 2).
- Produces: `AltTextGate.analyze(model:context:) throws -> [Finding]` — consumed by `QualityGateRunner` (Task 9).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/AltTextGateTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AltTextGate")
struct AltTextGateTests {
    private var emptyContext: GateContext { GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp")) }

    @Test("flags an image block with a src prop but no alt prop at all")
    func flagsMissingAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["img1::altText"])
    }

    @Test("does not flag an empty alt — intentionally decorative")
    func doesNotFlagEmptyAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg"), "alt": .string("")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }

    @Test("flags placeholder alt text like \"photo\"")
    func flagsPlaceholderAlt() throws {
        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg"), "alt": .string("Photo")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["img1::altText"])
    }

    @Test("does not flag a block with no src prop — not image-like")
    func ignoresNonImageBlocks() throws {
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])

        let findings = try AltTextGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter AltTextGateTests`
Expected: FAIL — `AltTextGate` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/AltTextGate.swift`:

```swift
import Foundation

/// Alt-text quality — hand-ported from `Resources/Template/scripts/a11y-validate.ts`'s
/// `validateImageAlt` (design doc §2: no cross-language sharing bridge exists, and the logic is
/// small enough that porting is cheaper than building one). The TS version parses raw HTML with
/// regexes; this version walks the typed `BlockModel` instead — simpler, not harder, since no HTML
/// parsing is needed. Kept independent from this point: a change to one does not automatically
/// apply to the other.
public enum AltTextGate {
    /// A block is image-like if it carries a `src` prop — deliberately not scoped to a specific
    /// `componentName`, since an image block could be an Astro `<Image>` component, a raw `text`-kind
    /// `<img>`, or (once theme blocks migrate, spec §4.1) a custom element — all of them carry `src`.
    private static func isImageLike(_ node: BlockNode) -> Bool {
        if case .string? = node.props["src"] { return true }
        return false
    }

    private static let placeholderPatterns: Set<String> = [
        "image", "photo", "picture", "img", "untitled", "placeholder", "screenshot", "banner", "hero",
    ]

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks where isImageLike(node) {
            guard case .string(let alt)? = node.props["alt"] else {
                findings.append(Finding(
                    blockId: node.id, category: .altText, severity: .warning,
                    message: "This image has no alt text — screen reader visitors won't know what it shows."))
                continue
            }
            let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue } // intentionally decorative, matches a11y-validate.ts
            if placeholderPatterns.contains(trimmed.lowercased()) {
                findings.append(Finding(
                    blockId: node.id, category: .altText, severity: .advisory,
                    message: "The alt text \"\(alt)\" is a placeholder — describe what the image actually shows."))
            }
        }
        return findings
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter AltTextGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/AltTextGate.swift Tests/AnglesiteCoreTests/AltTextGateTests.swift
git commit -m "feat(#1226): add AltTextGate"
```

---

## Task 6: `HeadingOrderGate`

Design doc §3: heading-skip detection, with a `setProp` fix when the heading's level is a prop rather than baked into `componentName`.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/HeadingOrderGate.swift`
- Test: `Tests/AnglesiteCoreTests/HeadingOrderGateTests.swift`

**Interfaces:**
- Consumes: `BlockModel.orderedBlocks`, `Finding`, `GateContext` (Task 2), `Op.setProp` (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`).
- Produces: `HeadingOrderGate.analyze(model:context:) throws -> [Finding]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/HeadingOrderGateTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("HeadingOrderGate")
struct HeadingOrderGateTests {
    private var emptyContext: GateContext { GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp")) }

    @Test("flags a skip from h2 to h4 in document order")
    func flagsSkip() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.map(\.id) == ["h4block::headingOrder"])
    }

    @Test("does not flag consecutive levels")
    func doesNotFlagConsecutive() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h3 = BlockNode(id: "h3block", kind: .text, componentName: "h3", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h3block"], blocks: ["h2block": h2, "h3block": h3])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.isEmpty)
    }

    @Test("offers a setProp fix when the skipped heading carries a level prop")
    func offersFixForLevelProp() throws {
        let h2 = BlockNode(id: "h2block", kind: .astro, componentName: "Heading", props: ["level": .number(2)], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .astro, componentName: "Heading", props: ["level": .number(4)], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.first?.fix == .setProp(blockId: "h4block", propName: "level", value: .number(3), previousValue: .number(4)))
    }

    @Test("offers no fix when the skipped heading has no level prop to rewrite")
    func noFixForTagEncodedLevel() throws {
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["h2block", "h4block"], blocks: ["h2block": h2, "h4block": h4])

        let findings = try HeadingOrderGate.analyze(model: model, context: emptyContext)

        #expect(findings.first?.fix == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter HeadingOrderGateTests`
Expected: FAIL — `HeadingOrderGate` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/HeadingOrderGate.swift`:

```swift
import Foundation

/// Heading-hierarchy validation — hand-ported from `a11y-validate.ts`'s `validateHeadingHierarchy`
/// (skip detection only; the multiple-h1 check is left to the deploy-time backstop, which runs over
/// the full built page rather than one page's live block model). See `AltTextGate`'s header comment
/// for why this is a port rather than a shared implementation.
public enum HeadingOrderGate {
    /// A block's heading level, or `nil` if it isn't a heading. Two representations exist in the
    /// model today (design doc §3): a `text`-kind block whose `componentName` is literally `"h1"`
    /// through `"h6"` (level fixed at authoring time, no `level` prop — the stub block palette's
    /// "Heading" entry works this way), or any block carrying a numeric `level` prop (an Astro
    /// `Heading` component). Only the second form can be corrected via `setProp` — see `fix(for:)`.
    private static func level(of node: BlockNode) -> Int? {
        if case .number(let n)? = node.props["level"] { return Int(n) }
        if node.kind == .text, node.componentName.count == 2, node.componentName.hasPrefix("h"),
           let level = Int(node.componentName.dropFirst()), (1...6).contains(level) {
            return level
        }
        return nil
    }

    private static func fix(for node: BlockNode, correctedLevel: Int) -> Op? {
        guard let previous = node.props["level"] else { return nil } // no `level` prop to rewrite
        return .setProp(blockId: node.id, propName: "level", value: .number(Double(correctedLevel)), previousValue: previous)
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        var previousLevel: Int?
        for node in model.orderedBlocks {
            guard let currentLevel = level(of: node) else { continue }
            defer { previousLevel = currentLevel }
            guard let previousLevel, currentLevel > previousLevel + 1 else { continue }
            let corrected = previousLevel + 1
            findings.append(Finding(
                blockId: node.id, category: .headingOrder, severity: .warning,
                message: "This heading jumps from h\(previousLevel) to h\(currentLevel) — screen reader visitors navigating by heading will think content is missing.",
                fix: fix(for: node, correctedLevel: corrected)))
        }
        return findings
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter HeadingOrderGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/HeadingOrderGate.swift Tests/AnglesiteCoreTests/HeadingOrderGateTests.swift
git commit -m "feat(#1226): add HeadingOrderGate"
```

---

## Task 7: `LinkIntegrityGate`

Design doc §2/§7: new — checks internal (`/`-rooted) hrefs against `GateContext.internalRoutes`. External hrefs are out of scope (owned by the deploy-time backstop).

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/LinkIntegrityGate.swift`
- Test: `Tests/AnglesiteCoreTests/LinkIntegrityGateTests.swift`

**Interfaces:**
- Consumes: `BlockModel.orderedBlocks`, `Finding`, `GateContext` (Task 2), `RichTextRun` (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`).
- Produces: `LinkIntegrityGate.analyze(model:context:) throws -> [Finding]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/LinkIntegrityGateTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LinkIntegrityGate")
struct LinkIntegrityGateTests {
    @Test("flags an internal href not present in internalRoutes")
    func flagsBrokenInternalLink() throws {
        let run = RichTextRun(kind: .link, text: "Read more", href: "/blog/missing")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: ["/blog/hello-world"], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["p1::linkIntegrity::richText.run.0"])
    }

    @Test("does not flag an internal href that resolves")
    func doesNotFlagResolvingLink() throws {
        let run = RichTextRun(kind: .link, text: "Read more", href: "/blog/hello-world")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: ["/blog/hello-world"], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("does not flag an external href — outside this gate's job")
    func doesNotFlagExternalLink() throws {
        let run = RichTextRun(kind: .link, text: "Anthropic", href: "https://anthropic.com")
        let paragraph = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [run])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["p1"], blocks: ["p1": paragraph])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("flags a broken href prop on an astro-kind link/button block")
    func flagsBrokenHrefProp() throws {
        let button = BlockNode(id: "btn1", kind: .astro, componentName: "Button", props: ["href": .string("/missing")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["btn1"], blocks: ["btn1": button])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        let findings = try LinkIntegrityGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["btn1::linkIntegrity::hrefProp"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter LinkIntegrityGateTests`
Expected: FAIL — `LinkIntegrityGate` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/LinkIntegrityGate.swift`:

```swift
import Foundation

/// Internal link-integrity checks — new (design doc §2/§7: no existing check in this repo does
/// this at all). Only internal (`/`-rooted) hrefs are checked against `GateContext.internalRoutes`;
/// external URLs need a network call and stay owned by the deploy-time backstop (design doc §2).
public enum LinkIntegrityGate {
    private struct LinkRef {
        let href: String
        let discriminator: String
    }

    /// Collects every href on `node`: rich-text link runs (recursing into `children`, since a link
    /// can wrap formatted text) plus a top-level `href` prop (an Astro link/button component).
    private static func links(in node: BlockNode) -> [LinkRef] {
        var refs: [LinkRef] = []
        func walk(_ runs: [RichTextRun], path: String) {
            for (index, run) in runs.enumerated() {
                let childPath = "\(path).\(index)"
                if run.kind == .link, let href = run.href {
                    refs.append(LinkRef(href: href, discriminator: "richText\(childPath)"))
                }
                if let children = run.children { walk(children, path: childPath) }
            }
        }
        if let richText = node.richText { walk(richText, path: "run") }
        if case .string(let href)? = node.props["href"] {
            refs.append(LinkRef(href: href, discriminator: "hrefProp"))
        }
        return refs
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks {
            for link in links(in: node) {
                guard link.href.hasPrefix("/") else { continue } // external — not this gate's job
                guard !context.internalRoutes.contains(link.href) else { continue }
                findings.append(Finding(
                    blockId: node.id, category: .linkIntegrity, discriminator: link.discriminator, severity: .warning,
                    message: "This link points to \"\(link.href)\", which doesn't match any page on the site — visitors who click it will hit a 404."))
            }
        }
        return findings
    }
}
```

Note: `RichTextRun.kind == .link` requires `RichTextRun.Kind` be `Equatable` — it already is (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`'s `RichTextRun.Kind` is `Codable, Sendable` and Swift synthesizes `Equatable` for a plain `enum` with no associated values automatically, so `==` is already available; no change needed there).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter LinkIntegrityGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/LinkIntegrityGate.swift Tests/AnglesiteCoreTests/LinkIntegrityGateTests.swift
git commit -m "feat(#1226): add LinkIntegrityGate"
```

---

## Task 8: `ImageWeightGate`

Design doc §2/§3/§7: detection only this slice — stats the resolved asset file under `GateContext.assetRoot`.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/ImageWeightGate.swift`
- Test: `Tests/AnglesiteCoreTests/ImageWeightGateTests.swift`

**Interfaces:**
- Consumes: `BlockModel.orderedBlocks`, `Finding`, `GateContext` (Task 2).
- Produces: `ImageWeightGate.analyze(model:context:) throws -> [Finding]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ImageWeightGateTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ImageWeightGate")
struct ImageWeightGateTests {
    @Test("flags an image asset over the size threshold")
    func flagsOversizedImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 600 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["img1::imageWeight"])
    }

    @Test("does not flag an image under the threshold")
    func doesNotFlagSmallImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 10 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("does not flag a src that doesn't resolve to a file on disk")
    func ignoresMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/does-not-exist.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter ImageWeightGateTests`
Expected: FAIL — `ImageWeightGate` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/ImageWeightGate.swift`:

```swift
import Foundation

/// Image file-size checks — new (design doc §2/§7). Detection only this slice: a real fix needs an
/// async, MCP-backed re-encode (design doc §3), deferred to a fast-follow. Stats the resolved asset
/// file directly under `GateContext.assetRoot` — no build required.
public enum ImageWeightGate {
    /// Above this, a photo is large enough to visibly slow a phone connection — matches the
    /// "photos this big load slowly on phones" framing in the design doc's example finding text.
    private static let maxBytes = 500 * 1024

    enum GateError: Error {
        case unreadableAsset(path: String, underlying: Error)
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks {
            guard case .string(let src)? = node.props["src"], src.hasPrefix("/") else { continue }
            let fileURL = context.assetRoot.appendingPathComponent(String(src.dropFirst()))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue } // not a local asset — nothing to stat
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            } catch {
                throw GateError.unreadableAsset(path: fileURL.path, underlying: error)
            }
            guard let size = attributes[.size] as? Int, size > maxBytes else { continue }
            let sizeKB = size / 1024
            findings.append(Finding(
                blockId: node.id, category: .imageWeight, severity: .warning,
                message: "This photo is \(sizeKB) KB — that large will load slowly on phones."))
        }
        return findings
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter ImageWeightGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/ImageWeightGate.swift Tests/AnglesiteCoreTests/ImageWeightGateTests.swift
git commit -m "feat(#1226): add ImageWeightGate"
```

---

## Task 9: `QualityGateRunner`

Design doc §3/§5: orchestrates all five checkers, isolating per-checker (category-level) failures.

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/QualityGates/QualityGateRunner.swift`
- Test: `Tests/AnglesiteCoreTests/QualityGateRunnerTests.swift`

**Interfaces:**
- Consumes: `ContrastGate.analyze`, `AltTextGate.analyze`, `HeadingOrderGate.analyze`, `LinkIntegrityGate.analyze`, `ImageWeightGate.analyze` (Tasks 3, 5–8).
- Produces: `QualityGateRunner.Result` (`findings: [Finding]`, `failedCategories: [FindingCategory]`), `QualityGateRunner.analyze(model:context:) -> Result` — consumed by `WYSIWYGCanvasController` (Task 10).

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/QualityGateRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("QualityGateRunner")
struct QualityGateRunnerTests {
    @Test("aggregates findings from every checker that has something to report")
    func aggregatesFindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 600 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let h2 = BlockNode(id: "h2block", kind: .text, componentName: "h2", props: [:], slots: [:], sourceSpan: [0, 0])
        let h4 = BlockNode(id: "h4block", kind: .text, componentName: "h4", props: [:], slots: [:], sourceSpan: [0, 0])
        let brokenLink = BlockNode(id: "p1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: [RichTextRun(kind: .link, text: "here", href: "/missing")])
        let model = BlockModel(
            path: "src/pages/index.astro", version: "v1",
            rootIds: ["img1", "h2block", "h4block", "p1"],
            blocks: ["img1": image, "h2block": h2, "h4block": h4, "p1": brokenLink])
        let context = GateContext(resolvedTokens: ["color-text": "#777777", "color-background": "#888888"], internalRoutes: [], assetRoot: root)

        let result = QualityGateRunner.analyze(model: model, context: context)

        let categories = Set(result.findings.map(\.category))
        #expect(categories == [.contrast, .altText, .headingOrder, .linkIntegrity, .imageWeight])
        #expect(result.failedCategories.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter QualityGateRunnerTests`
Expected: FAIL — `QualityGateRunner` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/WYSIWYG/QualityGates/QualityGateRunner.swift`:

```swift
import Foundation

/// Orchestrates all five checkers (spec §6) after every applied op (design doc §2/§3). Pure and
/// synchronous — no logging, no I/O beyond what the individual gates do — so it's trivial to unit
/// test and so `WYSIWYGCanvasController` (which does have `LogCenter` access, Task 10) decides what
/// to do with a failed category rather than this type reaching into logging itself.
///
/// Isolation is at the *category* level, not per-item within a category (one bad image doesn't get
/// its own try/catch inside `ImageWeightGate`) — this do/catch loop is the only place a checker
/// failure is caught, deliberately not covered by a forced-failure unit test: most CI containers run
/// as root, where POSIX permission bits don't block anything, so a chmod-based test that reliably
/// forces `ImageWeightGate`'s `attributesOfItem` to throw locally would be flaky in CI. The loop
/// itself is simple enough to review by inspection.
public enum QualityGateRunner {
    public struct Result: Sendable {
        public let findings: [Finding]
        public let failedCategories: [FindingCategory]
    }

    private static let gates: [(FindingCategory, (BlockModel, GateContext) throws -> [Finding])] = [
        (.contrast, ContrastGate.analyze),
        (.altText, AltTextGate.analyze),
        (.headingOrder, HeadingOrderGate.analyze),
        (.linkIntegrity, LinkIntegrityGate.analyze),
        (.imageWeight, ImageWeightGate.analyze),
    ]

    public static func analyze(model: BlockModel, context: GateContext) -> Result {
        var findings: [Finding] = []
        var failed: [FindingCategory] = []
        for (category, gate) in gates {
            do {
                findings.append(contentsOf: try gate(model, context))
            } catch {
                failed.append(category)
            }
        }
        return Result(findings: findings, failedCategories: failed)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter QualityGateRunnerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/QualityGates/QualityGateRunner.swift Tests/AnglesiteCoreTests/QualityGateRunnerTests.swift
git commit -m "feat(#1226): add QualityGateRunner"
```

---

## Task 10: Wire quality gates into `WYSIWYGCanvasController` and `PreviewModel`

Design doc §2/§3: re-run gates after every applied op and push the result toward the engine (the actual push script lands in Task 11's Swift-side counterpart below); `PreviewModel.enterEditMode` builds the `GateContext` from the open site's `Source/` directory.

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Modify: `Sources/AnglesiteApp/PreviewModel.swift:124-133` (`enterEditMode`)
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`, `Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift`

**Interfaces:**
- Consumes: `QualityGateRunner.analyze` (Task 9), `GateContext.build(fromSourceDirectory:)` (Task 4), `addOpAppliedListener` (Task 1).
- Produces: `WYSIWYGCanvasController.qualityGateContext: GateContext?`, `WYSIWYGCanvasController.lastQualityGateResult: QualityGateRunner.Result?`, `WYSIWYGCanvasController.pushQualityFindingsScript(for:) -> String` (static).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`, inside the `WYSIWYGCanvasControllerTests` struct (before the closing `}`):

```swift
    @Test("applying an op re-runs quality gates when a context is set")
    func appliedOpTriggersQualityGates() async {
        let node = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["img1"], blocks: ["img1": node])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.qualityGateContext = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: URL(fileURLWithPath: "/tmp"))

        _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

        #expect(controller.lastQualityGateResult?.findings.contains { $0.category == .altText } == true)
    }

    @Test("a nil qualityGateContext means quality gates never run")
    func noContextMeansNoAnalysis() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)

        _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

        #expect(controller.lastQualityGateResult == nil)
    }

    @Test("pushQualityFindingsScript(for:) builds a _handleQualityFindings call carrying the findings' exact JSON encoding")
    func pushQualityFindingsScriptBuildsCall() throws {
        let finding = Finding(blockId: "img1", category: .imageWeight, severity: .warning, message: "big")

        let script = WYSIWYGCanvasController.pushQualityFindingsScript(for: [finding])

        #expect(script.hasPrefix("window.__anglesiteWysiwygHost?._handleQualityFindings?.("))
        #expect(script.hasSuffix(")"))
        let jsonStart = script.index(script.startIndex, offsetBy: "window.__anglesiteWysiwygHost?._handleQualityFindings?.(".count)
        let json = String(script[jsonStart..<script.index(before: script.endIndex)])
        let decoded = try JSONDecoder().decode([Finding].self, from: Data(json.utf8))
        #expect(decoded == [finding])
    }
```

Append to `Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift`, inside the `PreviewModelWYSIWYGTests` struct (before the closing `}`):

```swift
    @Test("enterEditMode builds the canvas's qualityGateContext from the open site's Source/ directory")
    func editModeBuildsQualityGateContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ":root { --color-text: #111111; }".write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed for this test"))
        model.open(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))

        await model.enterEditMode(
            seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]),
            undoManager: nil)

        #expect(model.wysiwygCanvas?.qualityGateContext?.resolvedTokens["color-text"] == "#111111")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Run: `swift test --package-path . --filter PreviewModelWYSIWYGTests`
Expected: FAIL — `qualityGateContext`, `lastQualityGateResult`, `pushQualityFindingsScript` don't exist yet.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`, add near the other stored properties (after `webView`):

```swift
    /// Set by `PreviewModel.enterEditMode` once the open site's `Source/` directory is known — `nil`
    /// until then, in which case `runQualityGates` below simply has nothing to analyze against yet.
    var qualityGateContext: GateContext?

    /// The most recent quality-gate analysis result, or `nil` before the first applied op (or if
    /// `qualityGateContext` was never set). Exposed for testability without a real `WKWebView` — same
    /// reasoning as `mountScript(for:)`'s split from `mountEngine()` below.
    private(set) var lastQualityGateResult: QualityGateRunner.Result?
```

Add the second listener registration to `init`, right after the existing `addOpAppliedListener` call:

```swift
    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        addOpAppliedListener { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
        addOpAppliedListener { [weak self] _, _, newModel in
            self?.runQualityGates(model: newModel)
        }
    }
```

Add the analysis + push methods, near `mountEngine()`/`unmountEngine()`:

```swift
    /// Fires after every applied op (the `addOpAppliedListener` call in `init` above): re-runs all
    /// five quality gates against the new model and pushes the result to the engine. A `nil`
    /// `qualityGateContext` or `nil` `webView` both no-op harmlessly inside `pushQualityFindings` —
    /// the next applied op re-triggers this the same way.
    private func runQualityGates(model: BlockModel) {
        guard let qualityGateContext else { return }
        let result = QualityGateRunner.analyze(model: model, context: qualityGateContext)
        lastQualityGateResult = result
        pushQualityFindings(result.findings)
        for category in result.failedCategories {
            Task { await LogCenter.shared.append(source: "quality-gates", stream: .stderr, text: "\(category.rawValue) checker failed for \(model.path)") }
        }
    }

    /// Builds the `_handleQualityFindings` call for `findings` — factored out of
    /// `pushQualityFindings` the same way `mountScript(for:)` is factored out of `mountEngine()`, so
    /// it's testable without a real `WKWebView`. Returns a no-op script on the unreachable case that
    /// `findings` fails to encode.
    static func pushQualityFindingsScript(for findings: [Finding]) -> String {
        guard let data = try? JSONEncoder().encode(findings), let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "window.__anglesiteWysiwygHost?._handleQualityFindings?.(\(json))"
    }

    private func pushQualityFindings(_ findings: [Finding]) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.pushQualityFindingsScript(for: findings))
    }
```

In `Sources/AnglesiteApp/PreviewModel.swift`, in `enterEditMode(seedModel:undoManager:)`, insert the `qualityGateContext` line between the undo-manager seed and `wysiwygCanvas = canvas`:

```swift
    func enterEditMode(seedModel: BlockModel, undoManager: UndoManager?) async {
        let transport = StubWYSIWYGHostTransport(model: seedModel)
        let canvas = WYSIWYGCanvasController(initialModel: seedModel, transport: transport)
        canvas.undoCoordinator.undoManager = undoManager
        if let openSiteDirectory {
            canvas.qualityGateContext = GateContext.build(fromSourceDirectory: openSiteDirectory)
        }
        wysiwygCanvas = canvas
        if let webView {
            canvas.webView = webView
            canvas.mountEngine()
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Run: `swift test --package-path . --filter PreviewModelWYSIWYGTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/PreviewModel.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift
git commit -m "feat(#1226): re-run quality gates after every applied op"
```

---

## Task 11: `quality-gates.ts` — Finding type, `QualityGateTransport`, `QualityGateChips`

Design doc §3/§4: the engine-owned chip rendering module (spec §3.1: the engine owns "quality-gate chips").

**Files:**
- Create: `JS/wysiwyg-engine/src/quality-gates.ts`
- Test: `JS/wysiwyg-engine/test/quality-gates.test.ts`

**Interfaces:**
- Consumes: `computeHandleRect` (`JS/wysiwyg-engine/src/selection.ts`), `WysiwygEngine` (`JS/wysiwyg-engine/src/engine.ts`), `BlockId`, `Op`, `OpResult` (`JS/wysiwyg-engine/src/types.ts`).
- Produces: `Finding`, `FindingCategory`, `FindingSeverity`, `QualityGateTransport`, `CHIP_ATTR`, `QualityGateChips` — consumed by `native-host-transport.ts` (Task 12) and `mount.ts` (Task 13).

- [ ] **Step 1: Write the failing tests**

Create `JS/wysiwyg-engine/test/quality-gates.test.ts`:

```typescript
// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { QualityGateChips, CHIP_ATTR } from "../src/quality-gates.js";
import type { Finding, QualityGateTransport } from "../src/quality-gates.js";
import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BLOCK_ID_ATTR } from "../src/hit-test.js";
import type { BlockModel } from "../src/types.js";

class FakeQualityGateTransport implements QualityGateTransport {
  #listeners = new Set<(findings: Finding[]) => void>();
  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  push(findings: Finding[]): void {
    for (const listener of this.#listeners) listener(findings);
  }
}

function makeModel(): BlockModel {
  return {
    path: "src/pages/index.astro",
    version: "v1",
    rootIds: ["b1"],
    blocks: { b1: { id: "b1", kind: "astro", componentName: "Image", props: {}, slots: {}, sourceSpan: [0, 1] } },
  };
}

describe("QualityGateChips", () => {
  beforeEach(() => {
    document.body.innerHTML = `<div ${BLOCK_ID_ATTR}="b1"></div>`;
  });

  it("renders one chip per pushed finding, anchored near its block", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);

    const chips = document.querySelectorAll(`[${CHIP_ATTR}]`);
    expect(chips).toHaveLength(1);
    expect(chips[0]?.getAttribute(CHIP_ATTR)).toBe("b1::imageWeight");
    expect(chips[0]?.textContent).toContain("big photo");
  });

  it("stacks a second finding on the same block below the first instead of overlapping it", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const first: Finding = { id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt" };
    const second: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([first, second]);

    const firstChip = document.querySelector('[data-quality-chip-id="b1::altText"]') as HTMLElement;
    const secondChip = document.querySelector('[data-quality-chip-id="b1::imageWeight"]') as HTMLElement;
    expect(parseInt(secondChip.style.top, 10)).toBeGreaterThan(parseInt(firstChip.style.top, 10));
  });

  it("removes a chip once it's no longer in a later push (keyed diff)", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);

    transport.push([]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });

  it("updates an existing chip's message in place rather than replacing the element", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "600 KB" };

    transport.push([finding]);
    const firstElement = document.querySelector(`[${CHIP_ATTR}]`);

    transport.push([{ ...finding, message: "700 KB" }]);
    const secondElement = document.querySelector(`[${CHIP_ATTR}]`);

    expect(secondElement).toBe(firstElement);
    expect(secondElement?.textContent).toContain("700 KB");
  });

  it("falls back to a fixed page-level position when the finding's block has no on-screen element (e.g. the root sentinel)", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "__root__::contrast::color-text", blockId: "__root__", category: "contrast", severity: "warning", message: "low contrast" };

    transport.push([finding]);

    const chip = document.querySelector(`[${CHIP_ATTR}]`) as HTMLElement;
    expect(chip.style.top).toBe("8px");
    expect(chip.style.right).toBe("8px");
  });

  it("shows no Apply button when the finding has no fix", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const finding: Finding = { id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big photo" };

    transport.push([finding]);

    expect(document.querySelector(`[${CHIP_ATTR}] button`)).toBeNull();
  });

  it("clicking Apply submits the fix op and removes the chip on success", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const fix = { kind: "setProp", blockId: "b1", propName: "level", value: 3, previousValue: 4 } as const;
    const finding: Finding = { id: "b1::headingOrder", blockId: "b1", category: "headingOrder", severity: "warning", message: "heading skip", fix };
    transport.push([finding]);
    const button = document.querySelector(`[${CHIP_ATTR}] button`) as HTMLButtonElement;

    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });

  it("clicking Apply re-enables the button instead of removing the chip when the fix is rejected", async () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    vi.spyOn(engine, "submit").mockResolvedValue({ status: "rejected", reason: "version-mismatch" });
    const transport = new FakeQualityGateTransport();
    new QualityGateChips(engine, transport);
    const fix = { kind: "setProp", blockId: "b1", propName: "level", value: 3, previousValue: 4 } as const;
    const finding: Finding = { id: "b1::headingOrder", blockId: "b1", category: "headingOrder", severity: "warning", message: "heading skip", fix };
    transport.push([finding]);
    const button = document.querySelector(`[${CHIP_ATTR}] button`) as HTMLButtonElement;

    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);
    expect(button.disabled).toBe(false);
  });

  it("dispose() unsubscribes from the transport and removes all rendered chips", () => {
    const model = makeModel();
    const engine = new WysiwygEngine(model, new FixtureHost(model));
    const transport = new FakeQualityGateTransport();
    const chips = new QualityGateChips(engine, transport);
    transport.push([{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big" }]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(1);

    chips.dispose();

    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
    transport.push([{ id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt" }]);
    expect(document.querySelectorAll(`[${CHIP_ATTR}]`)).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- quality-gates`
Expected: FAIL — `src/quality-gates.ts` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `JS/wysiwyg-engine/src/quality-gates.ts`:

```typescript
import type { BlockId, Op, OpResult } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import { computeHandleRect } from "./selection.js";

export type FindingCategory = "contrast" | "altText" | "headingOrder" | "linkIntegrity" | "imageWeight";
export type FindingSeverity = "advisory" | "warning";

/** A live quality-gate finding (spec §6). Wire-compatible with the Swift `Finding` type in
 *  `Sources/AnglesiteCore/WYSIWYG/QualityGates/Finding.swift`. */
export interface Finding {
  id: string;
  blockId: BlockId;
  category: FindingCategory;
  severity: FindingSeverity;
  message: string;
  fix?: Op;
}

/** Host -> engine seam for quality-gate findings (design doc §3) — deliberately separate from
 *  `HostTransport`: findings are a push-only advisory stream, not part of the ops protocol, so a
 *  host with no quality-gate service can simply never call the listener. */
export interface QualityGateTransport {
  onFindings(listener: (findings: Finding[]) => void): () => void;
}

/** Attribute a rendered chip element carries its `Finding.id` under. */
export const CHIP_ATTR = "data-quality-chip-id";

/**
 * Renders quality-gate chips anchored to blocks (spec §3.1: the engine owns "quality-gate chips").
 * The host always pushes the full current finding set (design doc §3/§5, not a delta), so this does
 * its own keyed diff (by `Finding.id`) against what it has already rendered — a push never depends
 * on any previous one having arrived.
 */
export class QualityGateChips {
  #engine: WysiwygEngine;
  #container: HTMLElement;
  #chips = new Map<string, HTMLElement>();
  #unsubscribe: () => void;

  constructor(engine: WysiwygEngine, transport: QualityGateTransport, container: HTMLElement = document.body) {
    this.#engine = engine;
    this.#container = container;
    this.#unsubscribe = transport.onFindings((findings) => this.#render(findings));
  }

  dispose(): void {
    this.#unsubscribe();
    for (const chip of this.#chips.values()) chip.remove();
    this.#chips.clear();
  }

  #render(findings: Finding[]): void {
    const seen = new Set<string>();
    // Tracks how many findings for the same block have been placed so far in this push, so a
    // second/third finding on one block offsets downward instead of overlapping the first
    // (design doc §4: "stack rather than overlap") — order follows the order the host sent them.
    const countByBlock = new Map<BlockId, number>();
    for (const finding of findings) {
      seen.add(finding.id);
      const stackIndex = countByBlock.get(finding.blockId) ?? 0;
      countByBlock.set(finding.blockId, stackIndex + 1);
      const existing = this.#chips.get(finding.id);
      if (existing) {
        this.#updateChip(existing, finding, stackIndex);
      } else {
        const chip = this.#buildChip(finding, stackIndex);
        this.#chips.set(finding.id, chip);
        this.#container.appendChild(chip);
      }
    }
    for (const [id, chip] of this.#chips) {
      if (seen.has(id)) continue;
      chip.remove();
      this.#chips.delete(id);
    }
  }

  /** Positions `chip` near `blockId`'s on-screen element, offset downward by `stackIndex` steps so
   *  multiple findings on the same block stack rather than overlap — or, when there is no on-screen
   *  element (a page-level finding like contrast, anchored to the root sentinel; or a block that
   *  scrolled out of the DOM), in a fixed top-right tray rather than left unplaced. */
  #positionChip(chip: HTMLElement, blockId: BlockId, stackIndex: number): void {
    chip.style.position = "fixed";
    const rect = computeHandleRect(blockId);
    const offset = stackIndex * 28;
    if (!rect) {
      chip.style.top = `${8 + offset}px`;
      chip.style.right = "8px";
      chip.style.left = "";
      return;
    }
    chip.style.top = `${rect.y + offset}px`;
    chip.style.left = `${rect.x + rect.width}px`;
    chip.style.right = "";
  }

  #buildChip(finding: Finding, stackIndex: number): HTMLElement {
    const chip = document.createElement("div");
    chip.setAttribute(CHIP_ATTR, finding.id);
    chip.dataset.category = finding.category;
    chip.dataset.severity = finding.severity;
    this.#positionChip(chip, finding.blockId, stackIndex);
    this.#fillChip(chip, finding);
    return chip;
  }

  #updateChip(chip: HTMLElement, finding: Finding, stackIndex: number): void {
    this.#positionChip(chip, finding.blockId, stackIndex);
    chip.dataset.severity = finding.severity;
    this.#fillChip(chip, finding);
  }

  #fillChip(chip: HTMLElement, finding: Finding): void {
    chip.replaceChildren();
    const message = document.createElement("span");
    message.textContent = finding.message;
    chip.appendChild(message);
    const fix = finding.fix;
    if (!fix) return;
    const applyButton = document.createElement("button");
    applyButton.type = "button";
    applyButton.textContent = "Apply";
    applyButton.addEventListener("click", () => {
      applyButton.disabled = true;
      void this.#engine.submit(fix).then((result: OpResult) => {
        if (result.status === "applied") {
          chip.remove();
          this.#chips.delete(finding.id);
        } else {
          applyButton.disabled = false;
        }
      });
    });
    chip.appendChild(applyButton);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- quality-gates && npm run typecheck && npm run lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/quality-gates.ts JS/wysiwyg-engine/test/quality-gates.test.ts
git commit -m "feat(#1226): add quality-gate chip rendering (quality-gates.ts)"
```

---

## Task 12: `NativeHostTransport` also implements `QualityGateTransport`

Design doc §3/§8: one object owns the whole `window.__anglesiteWysiwygHost` bridge.

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/native-host-transport.ts`
- Modify: `JS/wysiwyg-engine/test/host/native-host-transport.test.ts`

**Interfaces:**
- Consumes: `Finding`, `QualityGateTransport` (Task 11).
- Produces: `NativeHostTransport` now also satisfies `QualityGateTransport` — consumed by `mount.ts` (Task 13).

- [ ] **Step 1: Write the failing test**

Append to `JS/wysiwyg-engine/test/host/native-host-transport.test.ts`, inside the `describe("NativeHostTransport", ...)` block (before the closing `});`):

```typescript
  it("notifies findings listeners when the native side pushes quality-gate findings", () => {
    const transport = new NativeHostTransport();
    const seen: unknown[] = [];
    const unsubscribe = transport.onFindings((findings) => seen.push(findings));
    const findings = [{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big" }];
    (window as any).__anglesiteWysiwygHost._handleQualityFindings(findings);
    expect(seen).toEqual([findings]);
    unsubscribe();
    (window as any).__anglesiteWysiwygHost._handleQualityFindings(findings);
    expect(seen).toHaveLength(1);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- native-host-transport`
Expected: FAIL — `transport.onFindings` doesn't exist yet.

- [ ] **Step 3: Implement**

Replace the full contents of `JS/wysiwyg-engine/src/host/native-host-transport.ts`:

```typescript
import type { HostTransport, OpEnvelope, OpResult, BlockModel } from "../types.js";
import type { Finding, QualityGateTransport } from "../quality-gates.js";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { wysiwyg?: { postMessage(body: unknown): void } } };
    __anglesiteWysiwygHost?: {
      _handleOpResult?: (requestId: string, result: OpResult) => void;
      _handleModelUpdate?: (model: BlockModel) => void;
      _handleQualityFindings?: (findings: Finding[]) => void;
    };
  }
}

/**
 * Adapts the engine's `HostTransport` interface to the native WKWebView bridge
 * (`Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`). Posts `submit-op` messages via
 * `window.webkit.messageHandlers.wysiwyg` and resolves pending promises when the native side calls
 * back into `window.__anglesiteWysiwygHost`.
 *
 * Also implements `QualityGateTransport` (design doc §3) — one object owns the whole
 * `window.__anglesiteWysiwygHost` bridge rather than splitting it across two classes, even though
 * the two interfaces stay conceptually separate (quality-gate findings are not part of the ops
 * protocol `HostTransport` itself covers).
 */
export class NativeHostTransport implements HostTransport, QualityGateTransport {
  #pending = new Map<string, (result: OpResult) => void>();
  #modelListeners = new Set<(model: BlockModel) => void>();
  #findingsListeners = new Set<(findings: Finding[]) => void>();

  constructor() {
    window.__anglesiteWysiwygHost = {
      _handleOpResult: (requestId, result) => {
        const resolve = this.#pending.get(requestId);
        if (!resolve) return;
        this.#pending.delete(requestId);
        resolve(result);
      },
      _handleModelUpdate: (model) => {
        for (const listener of this.#modelListeners) listener(model);
      },
      _handleQualityFindings: (findings) => {
        for (const listener of this.#findingsListeners) listener(findings);
      },
    };
  }

  sendOp(envelope: OpEnvelope): Promise<OpResult> {
    return new Promise((resolve) => {
      this.#pending.set(envelope.id, resolve);
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "submit-op", envelope });
    });
  }

  onModelUpdate(listener: (model: BlockModel) => void): () => void {
    this.#modelListeners.add(listener);
    return () => this.#modelListeners.delete(listener);
  }

  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#findingsListeners.add(listener);
    return () => this.#findingsListeners.delete(listener);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- native-host-transport && npm run typecheck && npm run lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/host/native-host-transport.ts JS/wysiwyg-engine/test/host/native-host-transport.test.ts
git commit -m "feat(#1226): NativeHostTransport also implements QualityGateTransport"
```

---

## Task 13: Wire `QualityGateChips` into `mount.ts`

Design doc §8: constructs/disposes the chip controller alongside the engine and rich-text editor.

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts`
- Modify: `JS/wysiwyg-engine/test/host/mount.test.ts`

**Interfaces:**
- Consumes: `QualityGateChips` (Task 11), `NativeHostTransport` (Task 12).
- Produces: `window.__anglesiteWysiwygQualityGates: QualityGateChips`.

- [ ] **Step 1: Write the failing tests**

Append to `JS/wysiwyg-engine/test/host/mount.test.ts`, inside the `describe(...)` block (before the closing `});`), and add `delete (window as any).__anglesiteWysiwygQualityGates;` to the existing `beforeEach`:

```typescript
  it("mount() constructs quality-gate chips wired to the same transport as the engine", () => {
    window.__anglesiteWysiwygMount!.mount(model);

    expect(window.__anglesiteWysiwygQualityGates).toBeDefined();
  });

  it("unmount() disposes the quality-gate chips and clears the global", () => {
    window.__anglesiteWysiwygMount!.mount(model);
    const chips = window.__anglesiteWysiwygQualityGates!;
    const disposeSpy = vi.spyOn(chips, "dispose");

    window.__anglesiteWysiwygMount!.unmount();

    expect(disposeSpy).toHaveBeenCalledOnce();
    expect(window.__anglesiteWysiwygQualityGates).toBeUndefined();
  });
```

The `beforeEach` becomes:

```typescript
  beforeEach(() => {
    document.body.innerHTML = "";
    delete (window as any).__anglesiteWysiwygEngine;
    delete (window as any).__anglesiteWysiwygRichTextEditor;
    delete (window as any).__anglesiteWysiwygQualityGates;
    delete (window as any).__anglesiteWysiwygHost;
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- mount`
Expected: FAIL — `window.__anglesiteWysiwygQualityGates` is never set yet.

- [ ] **Step 3: Implement**

Replace the full contents of `JS/wysiwyg-engine/src/host/mount.ts`:

```typescript
import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { QualityGateChips } from "../quality-gates.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel) => WysiwygEngine; unmount: () => void };
  }
}

// Disposes whatever is currently mounted (if anything) and clears the globals — the shared body
// of `unmount()` below, factored out so `mount()` can call it too (#1225 final-review round 2,
// Finding B) rather than only being reachable from the native `unmountEngine()` call. Safe to call
// when nothing is mounted: all three globals are `undefined` and the optional-chained calls no-op.
function disposeMounted(): void {
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    // Idempotent: dispose any already-mounted engine/RichTextEditor/QualityGateChips first (#1225
    // final-review round 2, Finding B) — see the original comment on this behavior for why.
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    // Same `transport` instance passed to both — `NativeHostTransport` implements both
    // `HostTransport` and `QualityGateTransport` (#1226 Task 12), so one object owns the whole
    // `window.__anglesiteWysiwygHost` bridge.
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    return engine;
  },
  // The counterpart to `mount` — called by `WYSIWYGCanvasController.unmountEngine()` (#1225
  // final-review fix wave, Findings 1/6) when Site ▸ Edit Page toggles off, or `PreviewView`'s
  // `updateNSView` observes the mounted controller change out from under an already-loaded page.
  unmount(): void {
    disposeMounted();
  },
};

// Never a web context menu (spec §8.1: "the engine hit-tests and reports the block under the
// cursor; the host builds the menu"). The engine resolves the right-clicked point to a block id
// via hit-test; the native host (`WYSIWYGScriptHandler`/`WYSIWYGBlockContextMenu`) builds and pops
// up a real NSMenu there. A `document`-level listener (rather than scoping to the mounted canvas
// root) matches `hitTest`'s own `doc.elementFromPoint` — it walks up from whatever's under the
// cursor to the nearest block-id-bearing ancestor, so it doesn't matter which element the event
// started on. No engine mounted yet, or the point misses every block (chrome, empty page margin):
// fall through to the platform's default context menu instead of showing an empty one.
document.addEventListener("contextmenu", (event) => {
  const engine = window.__anglesiteWysiwygEngine;
  if (!engine) return;
  const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
  if (!blockId) return;
  event.preventDefault();
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- mount && npm run typecheck && npm run lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/mount.test.ts
git commit -m "feat(#1226): mount QualityGateChips alongside the engine"
```

---

## Task 14: End-to-end Playwright coverage

Design doc §6: one real-browser test proving the chip → Apply → op-lands → chip-clears loop, plus a no-fix chip.

**Files:**
- Modify: `JS/wysiwyg-engine/e2e/fixture-page.ts`
- Create: `JS/wysiwyg-engine/e2e/quality-gates.spec.ts`

**Interfaces:**
- Consumes: `QualityGateChips`, `Finding` (Task 11); the fixture's existing `engine`/`canvas()` (already defined in `fixture-page.ts`).
- Produces: `window.__pushQualityFindings(findings: Finding[]) => void` — test-only fixture entry point.

- [ ] **Step 1: Wire a fixture-side quality-gate transport into `fixture-page.ts`**

In `JS/wysiwyg-engine/e2e/fixture-page.ts`, add an import near the top (alongside the other `src/*` imports):

```typescript
import { QualityGateChips } from "../src/quality-gates.js";
import type { Finding } from "../src/quality-gates.js";
```

After the existing `const dragReorder = new DragReorderController(...)` / `wireExternalDrop(...)` block and before `engine.onEvent((event) => { ... })`, add:

```typescript
class FixtureQualityGateTransport {
  #listeners = new Set<(findings: Finding[]) => void>();
  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  push(findings: Finding[]): void {
    for (const listener of this.#listeners) listener(findings);
  }
}

const qualityGateTransport = new FixtureQualityGateTransport();
const qualityGateChips = new QualityGateChips(engine, qualityGateTransport, canvas());
```

In the `declare global { interface Window { ... } }` block, add two members:

```typescript
    __qualityGateChips: QualityGateChips;
    __pushQualityFindings: (findings: Finding[]) => void;
```

Near the other `window.__*` assignments at the bottom of the file, add:

```typescript
window.__qualityGateChips = qualityGateChips;
window.__pushQualityFindings = (findings) => qualityGateTransport.push(findings);
```

- [ ] **Step 2: Write the e2e spec**

Create `JS/wysiwyg-engine/e2e/quality-gates.spec.ts`:

```typescript
import { test, expect } from "@playwright/test";

test("a pushed finding renders a chip, and applying its fix submits the op and clears the chip", async ({ page }) => {
  await page.goto("/fixture.html");

  await page.evaluate(() => {
    window.__pushQualityFindings([
      {
        id: "b1::headingOrder",
        blockId: "b1",
        category: "headingOrder",
        severity: "warning",
        message: "This heading jumps from h2 to h4 — screen reader visitors navigating by heading will think content is missing.",
        fix: { kind: "setProp", blockId: "b1", propName: "title", value: "Fixed", previousValue: "Welcome" },
      },
    ]);
  });

  const chip = page.locator('[data-quality-chip-id="b1::headingOrder"]');
  await expect(chip).toContainText("screen reader visitors navigating by heading");

  await chip.getByRole("button", { name: "Apply" }).click();

  await expect(chip).toHaveCount(0);
  const title = await page.evaluate(() => window.__engine.modelSync.current.blocks.b1?.props.title);
  expect(title).toBe("Fixed");
});

test("a finding with no fix renders a chip with no Apply button", async ({ page }) => {
  await page.goto("/fixture.html");

  await page.evaluate(() => {
    window.__pushQualityFindings([
      { id: "b1::altText", blockId: "b1", category: "altText", severity: "warning", message: "missing alt text" },
    ]);
  });

  const chip = page.locator('[data-quality-chip-id="b1::altText"]');
  await expect(chip).toContainText("missing alt text");
  await expect(chip.getByRole("button")).toHaveCount(0);
});
```

- [ ] **Step 3: Run to verify it passes**

Run: `cd JS/wysiwyg-engine && npm run test:e2e -- quality-gates`
Expected: PASS, both tests green.

- [ ] **Step 4: Run the full JS suite once more to confirm no regressions from the fixture change**

Run: `cd JS/wysiwyg-engine && npm test && npm run typecheck && npm run lint && npm run test:e2e`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/e2e/fixture-page.ts JS/wysiwyg-engine/e2e/quality-gates.spec.ts
git commit -m "test(#1226): add e2e coverage for quality-gate chips and apply"
```

---

## Final verification (after all 14 tasks)

- [ ] `swift test --package-path .` — full suite green.
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — app still builds.
- [ ] `cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test && npm run test:e2e`
- [ ] Re-read the design doc (`docs/superpowers/specs/2026-08-12-wysiwyg-live-quality-gates-design.md`) against the diff — confirm every §3–§8 item has a landed task.
- [ ] Update epic #1221's slice-5 checkbox and open the PR per `CONTRIBUTING.md` ▸ "Commits and pull requests" (PR template's Summary / Paired PR check / Test plan sections — this slice is app-only, no paired sidecar PR needed since no MCP schema changed), with `Closes #1226`.
