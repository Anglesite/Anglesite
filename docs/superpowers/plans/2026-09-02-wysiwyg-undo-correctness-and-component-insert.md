# WYSIWYG Undo Correctness + Component-Insert Manifest Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three WYSIWYG sidecar-transport gaps tracked in [#1602](https://github.com/Anglesite/Anglesite/issues/1602): (1) undoing a text edit restores to empty content instead of the original text, (2) undo of insert/delete can address the wrong node because the sidecar renumbers every node's id on each re-parse, and (3) inserting a component block writes an import statement pointing at a bare tag name instead of a real path.

**Architecture:** Items 1 and 3 are narrow, additive fixes inside the existing `PageModelBlockAdapter`/`WYSIWYGOpTranslator` pipeline. Item 2 is a real design reversal: this repo's `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md` (design decision 1) deliberately chose to compute undo inverses purely client-side (`WYSIWYGOpInverter.invert`) and never consume the sidecar's own computed `inverse` (already shipped in `anglesite-skills` — PR #435, merged, part of the vendored container image). That decision is now reversed: `SidecarWYSIWYGHostTransport` reports the server-computed `WireInverse` for every op it applies, alongside the usual `OpResult`, via a new opt-in `WYSIWYGServerInvertibleTransport` capability; `WYSIWYGUndoCoordinator`'s undo/redo stack stores a `WYSIWYGReversal` (either a plain `Op`, for transports without this capability, or a `WireInverse`, replayed verbatim past `WYSIWYGOpTranslator`) instead of a bare `Op`, and self-corrects on every fire: whenever a replay's own reply carries a fresh server inverse, that replaces whatever was optimistically registered as the next undo/redo step.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), the existing `AnglesiteCore`/`AnglesiteAppCore` WYSIWYG stack.

## Global Constraints

- **No new dependencies.**
- **Swift Testing only** (`@Suite`/`@Test`/`#expect`) — every WYSIWYG test file already uses it exclusively.
- **No JS/`wysiwyg-engine` changes are needed.** Confirmed: `JS/wysiwyg-engine/src/host/native-host-transport.ts` only posts `submit-op` across the WKWebView bridge into Swift's `WYSIWYGCanvasController.sendOp(_:)` — JS never talks to the sidecar's `apply_edit` directly, `SidecarWYSIWYGHostTransport` is the only caller. The undo/redo stack this plan changes (`WYSIWYGUndoCoordinator`) is itself a Swift-only construct wired to the native `UndoManager`, with no JS counterpart. `richText` already exists as a wire-mirrored `BlockNode` field on both sides (JS's `rich-text.ts:257` already reads it) — Task 1 needs no JS change, it just stops passing `nil`.
- **No paired sidecar PR.** The sidecar capability this plan consumes (`inverse: {op, component}` on every WYSIWYG structural/text/token op's `apply_edit` reply) already shipped in `anglesite-skills` (PR #435) and is already in the vendored container image (`EditReply.inverseNodeId`/`postWriteVersion` already narrowly decode a slice of it today). This plan is app-only.
- **Run before every commit**: `scripts/swift-test.sh --package-path .` and (for Task 7 onward, which touches `Sources/AnglesiteApp`) `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, per `CONTRIBUTING.md` ▸ Testing.
- **`WYSIWYGCanvasController`'s test target imports it as `AnglesiteAppCore`** (`@testable import AnglesiteAppCore` in `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`), even though the source file lives under `Sources/AnglesiteApp/` — match that existing import, don't "fix" it.

## Design decisions baked into this plan (read before objecting to a task's shape)

1. **Item 1's fix is a lossy-but-honest minimal baseline, not full formatting preservation.** `PageModel.Node.text` is a flat `String?` — the sidecar's page-model wire format carries no bold/italic/link mark data at all, only plain text. Mapping `node.text` into a single `RichTextRun(kind: .text, text:)` (per the issue's own suggested minimal fix) turns "undo restores to empty" into "undo restores to the correct plain text, losing only marks that existed before the FIRST edit of a session" — a strict improvement, not a complete fix. Preserving marks in the baseline needs a sidecar schema change (paired-PR territory) and is out of scope.
2. **Item 3's fix plumbs the pipe; it does not wire a real manifest-backed palette.** `WYSIWYGCanvasController.blockPalette`/`stubBlockPalette` is a hardcoded stand-in with no `blocks.manifest.json` identity at all (its own doc comment already names the real palette as pending, separate, tracked work). This plan adds a `manifestName` field to `BlockNode`/`BlockNodeContent`, populated by `PageModelBlockAdapter` from `PageModel.Node.block?.name` (the sidecar's `blocks.manifest.json` **display name** — confirmed against `anglesite-skills/server/block-manifest.mjs`'s `indexManifestByName`, which resolves `insertBlock`'s `manifestBlock` field against that same `name`, not a path or object key), and makes `WYSIWYGOpTranslator` prefer the sidecar-resolved `insertBlock(manifestBlock:)` wire form whenever it's set. The one concretely-fixed path today is `duplicateSelectedBlock()` — duplicating an existing manifest-registered component block now carries its identity forward and writes a correct import. Fresh inserts from the current stub palette remain unfixed (there is no manifest identity to plumb *from* there yet) — an explicit, named gap, not silently papered over.
3. **Item 2's fix self-corrects going forward, but does not solve every theoretically possible interleaving.** `UndoManager.registerUndo`'s registration must happen synchronously, before any `await` (`WYSIWYGUndoCoordinator.register`'s existing doc comment — verified empirically that `canRedo` never flips true otherwise). That means the *optimistic* re-registration on each fire can't wait for the just-fired `perform` to resolve before deciding what "the next step" is. This plan's answer: register optimistically as before (using the previous fire's `Op`/`WireInverse`, same as today), then — once `perform` resolves — if it reports a fresh, server-computed `WireInverse` for what it just did, swap out the optimistic registration for a corrected one (same `removeAllActions(withTarget:)` + re-register pattern the existing failure-rollback path already uses). Every WYSIWYG op family the sidecar's `component-structure-edit.mjs`/`design-token-edit.mjs`/`text-run-edit.mjs` handle (`insertBlock`, `deleteBlock`, `moveBlock`, `setProp`, `editText`, `setDesignToken`) computes an inverse unconditionally, so in practice this chain keeps self-healing across an entire undo/redo session once the first entry gets a server-computed reversal. What it does **not** fix: the untouched "redo the original op" slot of a registration is never itself corrected mid-flight — only the slot the just-completed `perform` reported on gets refreshed. This is a bounded, named residual gap (inherent to id-addressed editing without OT/CRDT), not a claim of perfect correctness under arbitrary interleavings.
4. **`OpResult`'s wire shape is untouched.** `OpResult` is `Codable` and crosses the JS↔Swift bridge (`WYSIWYGCanvasController.sendOp(_:)`'s JS-facing conformance). Rather than adding a field to it (which would ripple into `JS/wysiwyg-engine/src/types.ts` for no JS-side benefit — JS never needs to know about a server-computed reversal, since undo/redo is entirely native), the new capability (`WYSIWYGServerInvertibleTransport`) is a separate, additive Swift-only protocol that `SidecarWYSIWYGHostTransport` conforms to and `StubWYSIWYGHostTransport` does not; callers detect it with `as?` and fall back to `WYSIWYGOpInverter`'s client-computed inverse when the cast fails.

## Out of scope

- Wiring a real manifest-backed block palette (design decision 2).
- Preserving rich-text marks in the undo baseline (design decision 1).
- Full arbitrary-depth undo/redo correctness under intervening edits (design decision 3).
- Any change to `JS/wysiwyg-engine` (Global Constraints).
- A paired `anglesite-skills` PR (Global Constraints — the sidecar capability already shipped).

---

### Task 1: Text-edit undo baseline — populate `richText` from `PageModel.Node.text`

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift`
- Test: `Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift`

**Interfaces:**
- Consumes: `PageModel.Node.text: String?` (`PageModel.swift:29`), `RichTextRun` (`WYSIWYGOps.swift:42-57`).
- Produces: `BlockNode.richText` now non-`nil` for any node with non-`nil` `PageModel.Node.text` — consumed today by `JS/wysiwyg-engine/src/rich-text.ts:257`'s undo baseline (no Swift-side consumer changes needed).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift`:

```swift
    @Test func populatesRichTextFromNodeTextAsASingleTextRun() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(
                id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil,
                children: [
                    .init(id: "n1", kind: .element, tag: "p", attrs: [], span: .init(start: 1, end: 9), loc: nil,
                          text: "Hello, world", children: [], block: nil),
                ],
                block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.blocks["n1"]?.richText == [RichTextRun(kind: .text, text: "Hello, world")])
    }

    @Test func leavesRichTextNilWhenNodeHasNoText() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil, children: [], block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.blocks["n0"]?.richText == nil)
    }
```

- [ ] **Step 2: Run to verify the first test fails**

```bash
scripts/swift-test.sh --package-path . --filter PageModelBlockAdapterTests
```
Expected: `populatesRichTextFromNodeTextAsASingleTextRun` FAILS (`richText` is currently always `nil`); `leavesRichTextNilWhenNodeHasNoText` already passes.

- [ ] **Step 3: Populate `richText` in `walk`**

In `Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift`, change:

```swift
        blocks[node.id] = BlockNode(
            id: node.id,
            kind: blockKind(for: node),
            componentName: node.tag ?? "",
            props: props,
            slots: node.children.isEmpty ? [:] : ["default": node.children.map(\.id)],
            sourceSpan: [node.span.start ?? 0, node.span.end ?? 0],
            richText: nil) // rich-text runs come from a dedicated read, not the page-model tree; see Task 5's caveat
```

to:

```swift
        blocks[node.id] = BlockNode(
            id: node.id,
            kind: blockKind(for: node),
            componentName: node.tag ?? "",
            props: props,
            slots: node.children.isEmpty ? [:] : ["default": node.children.map(\.id)],
            sourceSpan: [node.span.start ?? 0, node.span.end ?? 0],
            // A lossy-but-honest baseline: the page model carries only a flat plain-text
            // snapshot, no bold/italic/link marks, so a single `.text` run is the most this can
            // ever be — but it's a strict improvement over the previous hardcoded `nil`, which
            // made `RichTextEditor`'s undo baseline (`rich-text.ts:257`) always empty, so undoing
            // any text edit restored to nothing rather than the original text (#1602 item 1).
            richText: node.text.map { [RichTextRun(kind: .text, text: $0)] })
```

- [ ] **Step 4: Run to verify both tests pass**

```bash
scripts/swift-test.sh --package-path . --filter PageModelBlockAdapterTests
```
Expected: PASS, all 5 tests (3 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift
git commit -m "fix(#1602): populate richText baseline from PageModel.Node.text"
```

---

### Task 2: Manifest identity plumbing — `BlockNode`/`BlockNodeContent` gain `manifestName`

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift` (`BlockNode`, `BlockNodeContent`)
- Modify: `Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift` (`walk`)
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift` (`.insertBlock`/`.deleteBlock` field pass-through)
- Modify: `Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift` (`applying(_:to:)`'s `.insertBlock` case — must copy the new field too, or `duplicateSelectedBlock`'s stub-transport tests would silently lose it on the very next round trip)
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (`duplicateSelectedBlock()`)
- Test: `Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift`, `Tests/AnglesiteCoreTests/WYSIWYGOpInverterTests.swift`

**Interfaces:**
- Consumes: `PageModel.Node.block?.name` (`PageModel.swift:114`, the sidecar's `blocks.manifest.json` display name).
- Produces: `BlockNode.manifestName: String?`, `BlockNodeContent.manifestName: String?` — consumed by Task 3's translator.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift`:

```swift
    @Test func populatesManifestNameForAResolvedManifestBlock() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(
                id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil,
                children: [
                    .init(id: "n1", kind: .component, tag: "Hcard", attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil, children: [],
                          block: .init(manifestPath: "src/components/Hcard.astro", name: "H-Card", description: "", icon: nil, slots: [])),
                ],
                block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.blocks["n1"]?.manifestName == "H-Card")
    }

    @Test func leavesManifestNameNilForANonManifestNode() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil, children: [], block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.blocks["n0"]?.manifestName == nil)
    }
```

Add to `Tests/AnglesiteCoreTests/WYSIWYGOpInverterTests.swift`:

```swift
    @Test("insertBlock/deleteBlock round-trip preserves manifestName")
    func manifestNamePreservedInRoundTrip() {
        let content = BlockNodeContent(kind: .astro, componentName: "Hcard", props: [:], slots: [:], sourceSpan: [0, 0], manifestName: "H-Card")
        let insertOp = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b9", block: content)

        let deleteOp = WYSIWYGOpInverter.invert(insertOp)
        guard case .deleteBlock(_, _, _, _, let block) = deleteOp else {
            Issue.record("Expected deleteBlock but got \(deleteOp)"); return
        }
        #expect(block.manifestName == "H-Card")

        let roundTrip = WYSIWYGOpInverter.invert(deleteOp)
        guard case .insertBlock(_, _, _, _, let roundTripContent) = roundTrip else {
            Issue.record("Expected insertBlock but got \(roundTrip)"); return
        }
        #expect(roundTripContent.manifestName == "H-Card")
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter "PageModelBlockAdapterTests|WYSIWYGOpInverterTests"
```
Expected: build failure — `manifestName` doesn't exist on `BlockNode`/`BlockNodeContent`, and the `BlockNodeContent` initializer doesn't accept it.

- [ ] **Step 3: Add `manifestName` to `BlockNode`/`BlockNodeContent`**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`, change `BlockNode`:

```swift
public struct BlockNode: Codable, Equatable, Sendable {
    public var id: BlockId
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    /// `[start, end)` byte offsets into the source file — a 2-element array, matching TS's tuple.
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?
    /// The `blocks.manifest.json` entry's owner-facing `name` (e.g. `"H-Card"`), when this node
    /// resolved to one (`PageModel.Node.block?.name` — see `PageModelBlockAdapter`). `nil` for a
    /// plain element/component the manifest doesn't know about. Lets `WYSIWYGOpTranslator` emit
    /// the sidecar-resolved `insertBlock(manifestBlock:)` wire form instead of guessing a
    /// `componentPath` from the bare tag name (#1602 item 3).
    public var manifestName: String?

    public init(id: BlockId, kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil, manifestName: String? = nil) {
        self.id = id
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
        self.manifestName = manifestName
    }
}
```

and `BlockNodeContent` identically (same new field, same initializer parameter added last):

```swift
public struct BlockNodeContent: Codable, Equatable, Sendable {
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?
    /// See `BlockNode.manifestName`'s doc comment — identical purpose, `BlockNodeContent` is
    /// `BlockNode` minus `id`.
    public var manifestName: String?

    public init(kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil, manifestName: String? = nil) {
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
        self.manifestName = manifestName
    }
}
```

Both new parameters default to `nil` so every existing call site (across Swift and the `Codable` wire decode, which uses `CodingKeys`-driven synthesis — unaffected since neither type has a custom `init(from:)`) compiles unchanged.

- [ ] **Step 4: Populate it in the adapter**

In `Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift`, add `manifestName: node.block?.name` to the `BlockNode(...)` construction in `walk`:

```swift
        blocks[node.id] = BlockNode(
            id: node.id,
            kind: blockKind(for: node),
            componentName: node.tag ?? "",
            props: props,
            slots: node.children.isEmpty ? [:] : ["default": node.children.map(\.id)],
            sourceSpan: [node.span.start ?? 0, node.span.end ?? 0],
            richText: node.text.map { [RichTextRun(kind: .text, text: $0)] },
            manifestName: node.block?.name)
```

- [ ] **Step 5: Pass it through `WYSIWYGOpInverter`**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift`, add `manifestName:` to both reconstructions:

```swift
        case .insertBlock(let parentId, let slot, let index, let newId, let block):
            return .deleteBlock(
                parentId: parentId, slot: slot, index: index, blockId: newId,
                block: BlockNode(id: newId, kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText, manifestName: block.manifestName))
        case .deleteBlock(let parentId, let slot, let index, let blockId, let block):
            return .insertBlock(
                parentId: parentId, slot: slot, index: index, newId: blockId,
                block: BlockNodeContent(kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText, manifestName: block.manifestName))
```

- [ ] **Step 6: Pass it through `StubWYSIWYGHostTransport`'s reducer**

In `Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift`, the `.insertBlock` case of `applying(_:to:)`:

```swift
        case .insertBlock(let parentId, let slot, let index, let newId, let content):
            blocks[newId] = BlockNode(id: newId, kind: content.kind, componentName: content.componentName, props: content.props, slots: content.slots, sourceSpan: content.sourceSpan, richText: content.richText, manifestName: content.manifestName)
            guard spliceIn(parentId: parentId, slot: slot, index: index, blockId: newId) else { return nil }
```

- [ ] **Step 7: Forward it in `duplicateSelectedBlock`**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`:

```swift
    func duplicateSelectedBlock() async {
        guard let id = selectedBlockId, let node = model.blocks[id], let location = locate(id) else { return }
        let newId = UUID().uuidString
        let content = BlockNodeContent(
            kind: node.kind, componentName: node.componentName, props: node.props,
            slots: node.slots, sourceSpan: node.sourceSpan, richText: node.richText, manifestName: node.manifestName)
        await submit(.insertBlock(parentId: location.parentId, slot: location.slot, index: location.index + 1, newId: newId, block: content))
    }
```

- [ ] **Step 8: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter "PageModelBlockAdapterTests|WYSIWYGOpInverterTests|StubWYSIWYGHostTransportTests"
```
Expected: PASS. Also re-run the full core suite once (`scripts/swift-test.sh --package-path .`) to confirm the two new initializer parameters didn't break any other `BlockNode`/`BlockNodeContent` construction — every existing call site should still compile unchanged since both new parameters default to `nil`.

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift Tests/AnglesiteCoreTests/WYSIWYGOpInverterTests.swift
git commit -m "feat(#1602): plumb manifest block identity through BlockNode/BlockNodeContent"
```

---

### Task 3: `WYSIWYGOpTranslator` prefers the `manifestBlock:` wire form when known

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpTranslator.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGOpTranslatorTests.swift`

**Interfaces:**
- Consumes: `BlockNodeContent.manifestName` (Task 2), `ComponentStructureEditBuilder.insertBlock(id:path:baseVersion:parentId:index:manifestBlock:)` (`ComponentStructureEditBuilder.swift:73-95`, already exists, currently unused by this translator).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/WYSIWYGOpTranslatorTests.swift`:

```swift
    @Test func insertBlockWithKnownManifestNameUsesManifestBlockWireForm() {
        let content = BlockNodeContent(
            kind: .astro, componentName: "Hcard", props: [:], slots: [:], sourceSpan: [0, 0], manifestName: "H-Card")
        let op = Op.insertBlock(parentId: "n2", slot: "default", index: 1, newId: "n7", block: content)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-1", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "insertBlock")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["manifestBlock"] == .string("H-Card"))
        #expect(component["node"] == nil) // manifestBlock and node are mutually exclusive wire forms
    }

    @Test func insertBlockWithNoManifestNameStillFallsBackToRawNodeInsert() {
        let content = BlockNodeContent(
            kind: .astro, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let op = Op.insertBlock(parentId: "n2", slot: "default", index: 1, newId: "n7", block: content)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-2", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        guard case .object(let component)? = message.component, case .object(let node)? = component["node"] else {
            Issue.record("expected component.node object"); return
        }
        #expect(node["kind"] == .string("component"))
        #expect(component["manifestBlock"] == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGOpTranslatorTests
```
Expected: the first new test FAILS (translator always uses `insertBlockNode`, never `insertBlock(manifestBlock:)`); the second already passes.

- [ ] **Step 3: Branch on `manifestName` in `translate`**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpTranslator.swift`, change the `.insertBlock` case:

```swift
        case .insertBlock(let parentId, _, let index, _, let block):
            if let manifestName = block.manifestName {
                // The sidecar resolves `manifestBlock` against its own `blocks.manifest.json`
                // and computes the correct `{tag, componentPath}` + frontmatter import itself —
                // preferred over `nodeSpec(for:)`'s guess whenever a manifest identity is known
                // (#1602 item 3; see `ComponentStructureEditBuilder.insertBlock(manifestBlock:)`'s
                // doc comment and this plan's design decision 2).
                return ComponentStructureEditBuilder.insertBlock(
                    id: requestId, path: path, baseVersion: baseVersion,
                    parentId: parentId, index: index, manifestBlock: manifestName)
            }
            return ComponentStructureEditBuilder.insertBlockNode(
                id: requestId, path: path, baseVersion: baseVersion,
                parentId: parentId, index: index, node: nodeSpec(for: block))
```

- [ ] **Step 4: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGOpTranslatorTests
```
Expected: PASS, all tests (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpTranslator.swift Tests/AnglesiteCoreTests/WYSIWYGOpTranslatorTests.swift
git commit -m "fix(#1602): prefer manifestBlock wire form for a known-manifest component insert"
```

---

### Task 4: `EditReply`/`MCPApplyEditRouter` decode the full server `inverse`

**Files:**
- Modify: `Sources/AnglesiteCore/EditRouter.swift` (`EditReply`)
- Modify: `Sources/AnglesiteCore/MCPApplyEditRouter.swift` (`parseStructured`, `Parsed`, `apply`)
- Test: `Tests/AnglesiteCoreTests/MCPApplyEditRouterTests.swift`

**Interfaces:**
- Produces: `EditReply.inverseOp: String?`, `EditReply.inverseComponent: JSONValue?` — the full `inverse.op`/`inverse.component` from the sidecar's `apply_edit` reply, alongside (not replacing) the existing narrow `inverseNodeId`/`postWriteVersion` decode. Consumed by Task 5.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/MCPApplyEditRouterTests.swift` (same fixture pattern as the existing `structuredReplyWithInverseExposesInverseFields` test just above it):

```swift
    @Test("Structured reply with inverse exposes the full inverseOp/inverseComponent")
    func structuredReplyWithInverseExposesFullInverse() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","inverse":{"op":"deleteBlock","component":{"path":"src/pages/about.astro","nodeId":"n42","baseVersion":"sha256:postwrite111"}}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.inverseOp == "deleteBlock")
        guard case .object(let component)? = reply.inverseComponent else {
            Issue.record("expected inverseComponent to decode as an object"); return
        }
        #expect(component["nodeId"] == .string("n42"))
        #expect(component["baseVersion"] == .string("sha256:postwrite111"))
    }

    @Test("Structured reply with no inverse key decodes nil inverseOp/inverseComponent")
    func structuredReplyWithNoInverseDecodesNilFullInverse() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.inverseOp == nil)
        #expect(reply.inverseComponent == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter MCPApplyEditRouterTests
```
Expected: build failure — `EditReply` has no `inverseOp`/`inverseComponent` members.

- [ ] **Step 3: Add the two fields to `EditReply`**

In `Sources/AnglesiteCore/EditRouter.swift`, add after the existing `postWriteVersion` field:

```swift
    /// Decoded verbatim from the apply_edit reply's `inverse.op` — the wire op name to replay to
    /// undo this exact write (e.g. `"deleteBlock"`). Unlike ``inverseNodeId``/``postWriteVersion``
    /// (a narrow, pre-existing decode for one specific insert-follow-up use), this is the general
    /// server-computed inverse this repo's WYSIWYG undo path now consumes (#1602 item 2, reversing
    /// `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s design decision
    /// 1) — see `SidecarWYSIWYGHostTransport`'s `WYSIWYGServerInvertibleTransport` conformance.
    /// `nil` when the reply carries no `inverse` key at all.
    public let inverseOp: String?
    /// Decoded verbatim from the apply_edit reply's `inverse.component` — the wire payload to
    /// send back through `EditRouter.apply(_:)` (paired with ``inverseOp`` as the `op`) to replay
    /// this inverse, bypassing `WYSIWYGOpTranslator`/`ComponentStructureEditBuilder` entirely. The
    /// sidecar stamps a fresh `baseVersion` onto this against the file's post-write hash
    /// (`apply-edit-dispatcher.mjs`), so it's always safe to send as-is without recomputing one.
    /// `nil` under the same condition as ``inverseOp``.
    public let inverseComponent: JSONValue?
```

and to the memberwise initializer's parameter list + assignments (append after `postWriteVersion`):

```swift
    public init(
        id: String,
        status: Status,
        message: String?,
        file: String? = nil,
        commit: String? = nil,
        result: ImageResult? = nil,
        before: String? = nil,
        after: String? = nil,
        op: String? = nil,
        model: ComponentModel? = nil,
        reason: String? = nil,
        newFile: String? = nil,
        inverseNodeId: String? = nil,
        postWriteVersion: String? = nil,
        inverseOp: String? = nil,
        inverseComponent: JSONValue? = nil
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.file = file
        self.commit = commit
        self.result = result
        self.before = before
        self.after = after
        self.op = op
        self.model = model
        self.reason = reason
        self.newFile = newFile
        self.inverseNodeId = inverseNodeId
        self.postWriteVersion = postWriteVersion
        self.inverseOp = inverseOp
        self.inverseComponent = inverseComponent
    }
```

- [ ] **Step 4: Decode them in `MCPApplyEditRouter.parseStructured`**

In `Sources/AnglesiteCore/MCPApplyEditRouter.swift`, extend the existing `inverse` block:

```swift
        var inverseNodeId: String?
        var postWriteVersion: String?
        var inverseOp: String?
        var inverseComponent: JSONValue?
        if let inverse = json["inverse"] as? [String: Any],
           let inverseComponentDict = inverse["component"] as? [String: Any] {
            inverseNodeId = inverseComponentDict["nodeId"] as? String
            postWriteVersion = inverseComponentDict["baseVersion"] as? String
            inverseOp = inverse["op"] as? String
            inverseComponent = JSONValue.from(inverseComponentDict)
        }
        if file == nil && commit == nil && image == nil && newFile == nil && model == nil && reason == nil
            && inverseNodeId == nil && postWriteVersion == nil && inverseOp == nil && inverseComponent == nil { return nil }
        return Parsed(
            file: file, commit: commit, result: image, newFile: newFile, model: model, reason: reason,
            inverseNodeId: inverseNodeId, postWriteVersion: postWriteVersion,
            inverseOp: inverseOp, inverseComponent: inverseComponent)
    }

    struct Parsed: Equatable {
        let file: String?
        let commit: String?
        let result: EditReply.ImageResult?
        let newFile: String?
        let model: ComponentModel?
        let reason: String?
        let inverseNodeId: String?
        let postWriteVersion: String?
        let inverseOp: String?
        let inverseComponent: JSONValue?
    }
```

- [ ] **Step 5: Thread `Parsed` into the `.applied` `EditReply` in `apply(_:)`**

In `Sources/AnglesiteCore/MCPApplyEditRouter.swift`, the `.applied` reply construction:

```swift
            let reply = EditReply(
                id: message.id,
                status: .applied,
                message: trimmed,
                file: parsed?.file,
                commit: parsed?.commit,
                result: parsed?.result,
                model: parsed?.model,
                newFile: parsed?.newFile,
                inverseNodeId: parsed?.inverseNodeId,
                postWriteVersion: parsed?.postWriteVersion,
                inverseOp: parsed?.inverseOp,
                inverseComponent: parsed?.inverseComponent
            )
```

(The `.failed` branch's `EditReply` construction does not carry `inverse` fields today and doesn't need to — a failed reply never gets replayed as an inverse.)

- [ ] **Step 6: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter MCPApplyEditRouterTests
```
Expected: PASS, all tests (existing + 2 new).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/EditRouter.swift Sources/AnglesiteCore/MCPApplyEditRouter.swift Tests/AnglesiteCoreTests/MCPApplyEditRouterTests.swift
git commit -m "feat(#1602): decode the full server-computed inverse op+component"
```

---

### Task 5: `WireInverse`/`WYSIWYGReversal`/`WYSIWYGServerInvertibleTransport` + `SidecarWYSIWYGHostTransport` conformance

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift` (new types + protocol)
- Modify: `Sources/AnglesiteCore/WYSIWYG/SidecarWYSIWYGHostTransport.swift` (conformance)
- Test: `Tests/AnglesiteCoreTests/SidecarWYSIWYGHostTransportTests.swift`

**Interfaces:**
- Produces: `WireInverse`, `WYSIWYGReversal` (`.op(Op)` / `.wire(WireInverse)`), `WYSIWYGServerInvertibleTransport` protocol with `sendOpReportingServerInverse(_:)` and `applyServerInverse(_:requestId:)` — consumed by Task 6/7.
- Consumes: `EditReply.inverseOp`/`inverseComponent` (Task 4).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/SidecarWYSIWYGHostTransportTests.swift` (read the file first — it already has `FakeEditRouter`/`emptyPageModel(version:)` helpers per the existing plan doc; reuse them exactly):

```swift
    @Test func sendOpReportingServerInverseSurfacesTheDecodedInverse() async {
        let pageModelClient = PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh111111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let editRouter = FakeEditRouter(reply: EditReply(
            id: "req-1", status: .applied, message: nil,
            inverseOp: "deleteBlock", inverseComponent: .object(["nodeId": .string("n7"), "baseVersion": .string("sha256:fresh111111")])))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let (result, serverInverse) = await transport.sendOpReportingServerInverse(OpEnvelope(id: "req-1", targetVersion: "sha256:stale000000", op: op))

        guard case .applied = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(serverInverse?.op == "deleteBlock")
        #expect(serverInverse?.component == .object(["nodeId": .string("n7"), "baseVersion": .string("sha256:fresh111111")]))
    }

    @Test func sendOpReportingServerInverseIsNilWhenReplyCarriesNoInverse() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh111111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-1", status: .applied, message: nil))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let (_, serverInverse) = await transport.sendOpReportingServerInverse(OpEnvelope(id: "req-1", targetVersion: "sha256:stale000000", op: op))

        #expect(serverInverse == nil)
    }

    @Test func applyServerInverseReplaysVerbatimAndReportsItsOwnFreshInverse() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:afterundo111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        var capturedMessage: EditMessage?
        let editRouter = RecordingEditRouter(reply: EditReply(
            id: "undo-1", status: .applied, message: nil,
            inverseOp: "insertBlock", inverseComponent: .object(["parentId": .string("n2")]))) { capturedMessage = $0 }
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let inverse = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("n7"), "baseVersion": .string("sha256:beforeundo")]))
        let (result, freshInverse) = await transport.applyServerInverse(inverse, requestId: "undo-1")

        guard case .applied = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(capturedMessage?.op == "deleteBlock")
        #expect(capturedMessage?.component == .object(["nodeId": .string("n7"), "baseVersion": .string("sha256:beforeundo")]))
        #expect(capturedMessage?.id == "undo-1")
        #expect(freshInverse?.op == "insertBlock")
    }
```

`RecordingEditRouter` doesn't exist yet — add it alongside the existing `FakeEditRouter` in the same test file:

```swift
    struct RecordingEditRouter: EditRouter {
        let reply: EditReply
        let onApply: (EditMessage) -> Void
        func apply(_ message: EditMessage) async -> EditReply {
            onApply(message)
            return reply
        }
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter SidecarWYSIWYGHostTransportTests
```
Expected: build failure — `sendOpReportingServerInverse`/`applyServerInverse`/`WireInverse` don't exist, and `EditReply`'s `inverseOp`/`inverseComponent` initializer params from Task 4 aren't wired into any transport method yet.

- [ ] **Step 3: Add the new types + protocol**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift`, append:

```swift
/// The server's own computed reversal for one applied WYSIWYG edit (`anglesite-skills#435`) —
/// the wire op name + payload to send back through `EditRouter.apply(_:)` verbatim, bypassing
/// `WYSIWYGOpTranslator`/`ComponentStructureEditBuilder` entirely. Computed by the sidecar
/// against the file's POST-write tree, so — unlike a locally-computed `WYSIWYGOpInverter.invert`
/// result — its embedded node ids stay correct even though the sidecar renumbers every node on
/// each re-parse (see `docs/superpowers/plans/2026-09-02-wysiwyg-undo-correctness-and-component-insert.md`'s
/// design decision 3, which reverses
/// `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s design decision 1).
public struct WireInverse: Sendable, Equatable {
    /// The wire op name to replay (e.g. `"deleteBlock"`).
    public let op: String
    /// The wire's `component` payload, verbatim — already includes a fresh `baseVersion`
    /// stamped by the sidecar against the file's post-write hash (`apply-edit-dispatcher.mjs`).
    public let component: JSONValue

    public init(op: String, component: JSONValue) {
        self.op = op
        self.component = component
    }
}

/// One undo/redo stack entry's reversal step: either a plain ``Op`` (translated fresh via
/// `WYSIWYGOpTranslator` against whatever ids it embeds — the only kind `WYSIWYGOpInverter.invert`
/// can ever produce, and the only kind a non-sidecar transport like `StubWYSIWYGHostTransport`
/// supports), or a ``WireInverse`` (replayed verbatim, bypassing the `Op`/translator layer
/// entirely). `WYSIWYGUndoCoordinator` stores this instead of a bare `Op` so a transport
/// conforming to ``WYSIWYGServerInvertibleTransport`` can supply an always-correct reversal
/// instead of a client-guessed one.
public enum WYSIWYGReversal: Sendable, Equatable {
    case op(Op)
    case wire(WireInverse)
}

/// Optional transport capability: alongside the usual ``WYSIWYGHostTransport/sendOp(_:)``, also
/// reports the server-computed ``WireInverse`` for the op it just applied, and can replay a
/// previously-reported ``WireInverse`` directly to undo/redo it. Only `SidecarWYSIWYGHostTransport`
/// conforms — `StubWYSIWYGHostTransport` has no real backing store to compute one against, so
/// callers must fall back to `WYSIWYGOpInverter`'s client-computed inverse when a transport isn't
/// this type, or when a specific reply doesn't carry one.
public protocol WYSIWYGServerInvertibleTransport: WYSIWYGHostTransport {
    /// Like `sendOp(_:)`, but also returns the server-computed reversal for `envelope.op`, when
    /// the applied reply carried one (in practice every WYSIWYG structural/text/token op does —
    /// see `anglesite-skills/server/component-structure-edit.mjs`/`design-token-edit.mjs` — so
    /// `nil` alongside `.applied` should be rare, but is handled, not assumed impossible). `nil`
    /// on a `.rejected` result (nothing was applied to invert).
    func sendOpReportingServerInverse(_ envelope: OpEnvelope) async -> (result: OpResult, serverInverse: WireInverse?)

    /// Replays `inverse` verbatim via the underlying `EditRouter` (using `requestId` as the
    /// replayed `EditMessage`'s correlation id), bypassing `WYSIWYGOpTranslator` entirely, then
    /// re-fetches + adapts the model exactly like `sendOp(_:)`'s `.applied` path. Returns the SAME
    /// `(result, serverInverse)` shape as `sendOpReportingServerInverse` so an undo/redo chain
    /// keeps self-correcting: on success, `serverInverse` is THIS call's own freshly-computed
    /// reversal — the accurate way to reverse what replaying `inverse` just did — used to correct
    /// whatever gets registered as the next undo/redo step.
    func applyServerInverse(_ inverse: WireInverse, requestId: String) async -> (result: OpResult, serverInverse: WireInverse?)
}
```

- [ ] **Step 4: Refactor `SidecarWYSIWYGHostTransport` to conform**

In `Sources/AnglesiteCore/WYSIWYG/SidecarWYSIWYGHostTransport.swift`, replace the existing `sendOp(_:)` method with a thin wrapper plus two new methods and a shared private helper. Replace:

```swift
    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let message = WYSIWYGOpTranslator.translate(
            envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion, rootId: rootId)
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            if case .insertBlock(_, _, _, _, let block) = envelope.op {
                if let rejection = await applyInsertFollowUp(block, insertReply: reply, requestId: envelope.id) {
                    return rejection
                }
            }
            do {
                let fresh = try await pageModelClient.fetch(path: path)
                rootId = fresh.tree.id
                return .applied(model: PageModelBlockAdapter.adapt(fresh))
            } catch {
                // The write landed but the re-fetch failed — surface as a host error with no
                // fresh model rather than silently claiming success without a model to show.
                return .rejected(reason: .hostError, message: "edit applied but re-fetch failed: \(error)", freshModel: nil)
            }
        case .failed:
            let reason: OpRejectionReason = (reply.reason == "stale") ? .versionMismatch : .hostError
            var freshModel: BlockModel?
            if reason == .versionMismatch, let fresh = try? await pageModelClient.fetch(path: path) {
                rootId = fresh.tree.id
                freshModel = PageModelBlockAdapter.adapt(fresh)
            }
            return .rejected(reason: reason, message: reply.message, freshModel: freshModel)
        case .ambiguous, .preview:
            // Neither status is reachable here: `EditMessage`'s `dryRun` defaults false (no
            // preview requested) and these ops don't use `selector`-based matching (no ambiguity
            // path). Treat defensively as a host error rather than force-unwrapping an assumption.
            return .rejected(reason: .hostError, message: "unexpected reply status: \(reply.status)", freshModel: nil)
        }
    }
```

with:

```swift
    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        await sendOpReportingServerInverse(envelope).result
    }

    public func sendOpReportingServerInverse(_ envelope: OpEnvelope) async -> (result: OpResult, serverInverse: WireInverse?) {
        let message = WYSIWYGOpTranslator.translate(
            envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion, rootId: rootId)
        var insertBlockContent: BlockNodeContent?
        if case .insertBlock(_, _, _, _, let block) = envelope.op {
            insertBlockContent = block
        }
        return await applyMessageAndAdapt(message, insertBlockContent: insertBlockContent, requestId: envelope.id)
    }

    public func applyServerInverse(_ inverse: WireInverse, requestId: String) async -> (result: OpResult, serverInverse: WireInverse?) {
        // A server-computed inverse for `deleteBlock` reinstates via `NodeSpec.raw` — full,
        // already-serialized markup — so unlike a fresh `insertBlock` translated from an `Op`,
        // replaying one never needs the props/richText follow-up dance below.
        let message = EditMessage(id: requestId, path: path, selector: nil, op: inverse.op, component: inverse.component, value: nil)
        return await applyMessageAndAdapt(message, insertBlockContent: nil, requestId: requestId)
    }

    /// Shared apply+re-fetch+adapt core for `sendOpReportingServerInverse`/`applyServerInverse` —
    /// factors out what used to be `sendOp(_:)`'s whole body, adding the reply's own
    /// `inverseOp`/`inverseComponent` decode (Task 4) into a `WireInverse` on success.
    /// `insertBlockContent` is non-nil only for a translated `Op.insertBlock` (never for a
    /// replayed `WireInverse` — see `applyServerInverse`'s doc comment above).
    private func applyMessageAndAdapt(
        _ message: EditMessage, insertBlockContent: BlockNodeContent?, requestId: String
    ) async -> (result: OpResult, serverInverse: WireInverse?) {
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            if let insertBlockContent {
                if let rejection = await applyInsertFollowUp(insertBlockContent, insertReply: reply, requestId: requestId) {
                    return (rejection, nil)
                }
            }
            do {
                let fresh = try await pageModelClient.fetch(path: path)
                rootId = fresh.tree.id
                let serverInverse: WireInverse?
                if let inverseOp = reply.inverseOp, let inverseComponent = reply.inverseComponent {
                    serverInverse = WireInverse(op: inverseOp, component: inverseComponent)
                } else {
                    serverInverse = nil
                }
                return (.applied(model: PageModelBlockAdapter.adapt(fresh)), serverInverse)
            } catch {
                // The write landed but the re-fetch failed — surface as a host error with no
                // fresh model rather than silently claiming success without a model to show.
                return (.rejected(reason: .hostError, message: "edit applied but re-fetch failed: \(error)", freshModel: nil), nil)
            }
        case .failed:
            let reason: OpRejectionReason = (reply.reason == "stale") ? .versionMismatch : .hostError
            var freshModel: BlockModel?
            if reason == .versionMismatch, let fresh = try? await pageModelClient.fetch(path: path) {
                rootId = fresh.tree.id
                freshModel = PageModelBlockAdapter.adapt(fresh)
            }
            return (.rejected(reason: reason, message: reply.message, freshModel: freshModel), nil)
        case .ambiguous, .preview:
            // Neither status is reachable here: `EditMessage`'s `dryRun` defaults false (no
            // preview requested) and these ops don't use `selector`-based matching (no ambiguity
            // path). Treat defensively as a host error rather than force-unwrapping an assumption.
            return (.rejected(reason: .hostError, message: "unexpected reply status: \(reply.status)", freshModel: nil), nil)
        }
    }
```

Also change the type declaration line to declare the new conformance:

```swift
public actor SidecarWYSIWYGHostTransport: WYSIWYGServerInvertibleTransport {
```

(`WYSIWYGServerInvertibleTransport` refines `WYSIWYGHostTransport`, so this single change covers both.)

- [ ] **Step 5: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter SidecarWYSIWYGHostTransportTests
```
Expected: PASS, all tests (existing + 3 new). Re-run the full core suite once too, since `applyInsertFollowUp` and the pre-existing insert/stale-reason tests now route through the shared `applyMessageAndAdapt` helper — confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift Sources/AnglesiteCore/WYSIWYG/SidecarWYSIWYGHostTransport.swift Tests/AnglesiteCoreTests/SidecarWYSIWYGHostTransportTests.swift
git commit -m "feat(#1602): add WYSIWYGServerInvertibleTransport, wire it into the sidecar transport"
```

---

### Task 6: `WYSIWYGUndoCoordinator` generalizes to `WYSIWYGReversal` with self-correcting re-registration

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGUndoCoordinatorTests.swift` (full rewrite — every existing test's `Performer`/assertions change shape)

**Interfaces:**
- Consumes: `WYSIWYGReversal`, `WireInverse` (Task 5).
- Produces: `WYSIWYGUndoCoordinator.Performer = @MainActor (WYSIWYGReversal) async -> WYSIWYGPerformOutcome`, `WYSIWYGPerformOutcome` (`.rejected` / `.applied(freshInverse: WYSIWYGReversal?)`), `registerApplied(op: Op, inverse: WYSIWYGReversal)` — consumed by Task 7.

- [ ] **Step 1: Rewrite the test file (RED first)**

Replace the entire contents of `Tests/AnglesiteCoreTests/WYSIWYGUndoCoordinatorTests.swift` with:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGUndoCoordinator")
@MainActor
struct WYSIWYGUndoCoordinatorTests {
    @Test("registering an applied op sets a truthful action name and undoing calls perform with the inverse")
    func undoCallsPerformWithInverse() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: .op(inverse))

        // `undoActionName` is the bare name ("Edit"); the "Undo " prefix only appears on the
        // localized menu title — verified against a real `UndoManager` instance, contra the
        // task brief's sample assertion.
        #expect(undoManager.undoMenuItemTitle == "Undo Edit")
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(inverse)])
    }

    @Test("undoing then redoing performs the inverse then the original op")
    func redoPerformsOriginal() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        coordinator.registerApplied(op: op, inverse: .op(WYSIWYGOpInverter.invert(op)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        undoManager.redo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.op(WYSIWYGOpInverter.invert(op)), .op(op)])
    }

    @Test("a rejected perform does not leave a stale opposite-direction step on the stack")
    func rejectedPerformDoesNotReRegister() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .rejected // simulates a rejected op, e.g. a version-mismatch conflict
        }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: .op(inverse))

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.op(inverse)])
        #expect(undoManager.canRedo == false)
    }

    @Test("coalesces consecutive same-session editText commits into a single undo entry (#1225 Finding 5)")
    func coalescesSameSessionEditTextCommits() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        // Three debounced commits from the SAME `RichTextEditor.enter()` session: each carries the
        // identical `previousRuns` (the session's fixed baseline, per that type's doc comment) —
        // only `runs` (the live text) advances.
        let baseline = [RichTextRun(kind: .text, text: "Hello")]
        let tick1 = [RichTextRun(kind: .text, text: "Hello,")]
        let tick2 = [RichTextRun(kind: .text, text: "Hello, w")]
        let tick3 = [RichTextRun(kind: .text, text: "Hello, world")]

        let op1 = Op.editText(blockId: "b1", runs: tick1, previousRuns: baseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))
        let op2 = Op.editText(blockId: "b1", runs: tick2, previousRuns: baseline)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))
        let op3 = Op.editText(blockId: "b1", runs: tick3, previousRuns: baseline)
        coordinator.registerApplied(op: op3, inverse: .op(WYSIWYGOpInverter.invert(op3)))

        // One entry, not three: a single undo restores all the way back to the session's original
        // baseline in one step.
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op3))])
        #expect(undoManager.canUndo == false) // nothing left to undo past the coalesced entry
        #expect(undoManager.canRedo == true)

        undoManager.redo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op3)), .op(op3)])
    }

    @Test("does not coalesce editText commits from two separate sessions on the same block")
    func doesNotCoalesceAcrossSeparateSessions() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        // Session 1: baseline "Hello" -> "Hello, world".
        let sessionOneBaseline = [RichTextRun(kind: .text, text: "Hello")]
        let sessionOneFinal = [RichTextRun(kind: .text, text: "Hello, world")]
        let op1 = Op.editText(blockId: "b1", runs: sessionOneFinal, previousRuns: sessionOneBaseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))

        // Session 2 (a later, separate `enter()`): its baseline is session 1's FINAL text (enter()
        // re-reads the live model) — a genuinely different edit, not a continuation.
        let sessionTwoFinal = [RichTextRun(kind: .text, text: "Hello, world!!")]
        let op2 = Op.editText(blockId: "b1", runs: sessionTwoFinal, previousRuns: sessionOneFinal)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))

        // Two entries, not one: undoing once only reverts session 2, leaving session 1's edit
        // still on the stack and still recoverable.
        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op2))])
        #expect(undoManager.canUndo == true)

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(op2)), .op(WYSIWYGOpInverter.invert(op1))])
    }

    @Test("does not coalesce editText commits for two different blocks")
    func doesNotCoalesceAcrossDifferentBlocks() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let baseline = [RichTextRun(kind: .text, text: "Hi")]
        let opA = Op.editText(blockId: "a", runs: [RichTextRun(kind: .text, text: "Hi there")], previousRuns: baseline)
        coordinator.registerApplied(op: opA, inverse: .op(WYSIWYGOpInverter.invert(opA)))
        let opB = Op.editText(blockId: "b", runs: [RichTextRun(kind: .text, text: "Hi you")], previousRuns: baseline)
        coordinator.registerApplied(op: opB, inverse: .op(WYSIWYGOpInverter.invert(opB)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed == [.op(WYSIWYGOpInverter.invert(opB))])
        #expect(undoManager.canUndo == true) // block "a"'s edit is still a separate entry
    }

    @Test("a coalesced entry does not resurrect after an intervening undo/redo")
    func coalescingStopsAfterUndoRedo() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let baseline = [RichTextRun(kind: .text, text: "Hi")]
        let tick1 = [RichTextRun(kind: .text, text: "Hi!")]
        let op1 = Op.editText(blockId: "b1", runs: tick1, previousRuns: baseline)
        coordinator.registerApplied(op: op1, inverse: .op(WYSIWYGOpInverter.invert(op1)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        undoManager.redo()
        await coordinator.pendingPerform?.value

        // A further same-block, same-baseline commit arriving after the undo/redo round trip must
        // NOT coalesce into the entry the redo just re-registered — it starts a fresh entry.
        let tick2 = [RichTextRun(kind: .text, text: "Hi!!")]
        let op2 = Op.editText(blockId: "b1", runs: tick2, previousRuns: baseline)
        coordinator.registerApplied(op: op2, inverse: .op(WYSIWYGOpInverter.invert(op2)))

        undoManager.undo()
        await coordinator.pendingPerform?.value
        #expect(performed.last == .op(WYSIWYGOpInverter.invert(op2)))
        #expect(undoManager.canUndo == true) // op1's redo-registered entry is still there beneath it
    }

    @Test("undoing a step whose registered reversal is a WireInverse replays it verbatim (#1602 item 2)")
    func undoReplaysWireInverseVerbatim() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.deleteBlock(
            parentId: rootParentID, slot: "main", index: 0, blockId: "n5",
            block: BlockNode(id: "n5", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let wireInverse = WireInverse(
            op: "insertBlock",
            component: .object(["parentId": .string(rootParentID), "index": .int(0), "node": .object(["kind": .string("raw"), "markup": .string("<p>hi</p>")])]))
        coordinator.registerApplied(op: op, inverse: .wire(wireInverse))

        undoManager.undo()
        await coordinator.pendingPerform?.value

        #expect(performed == [.wire(wireInverse)])
    }

    @Test("a freshInverse reported by perform replaces the optimistically-registered next step (#1602 item 2)")
    func freshInverseCorrectsNextRegisteredStep() async {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [WYSIWYGReversal] = []
        let staleGuess = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("stale-n5")]))
        let freshAnswer = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("real-n7")]))
        let coordinator = WYSIWYGUndoCoordinator { step in
            performed.append(step)
            // The very first perform (undoing the original insert) reports back the server's real
            // post-write inverse, correcting the redo step the registration guessed at.
            if performed.count == 1 {
                return .applied(freshInverse: .wire(freshAnswer))
            }
            return .applied(freshInverse: nil)
        }
        coordinator.undoManager = undoManager

        let op = Op.insertBlock(
            parentId: rootParentID, slot: "main", index: 0, newId: "n5",
            block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        coordinator.registerApplied(op: op, inverse: .wire(staleGuess))

        undoManager.undo() // performs .wire(staleGuess); its reply corrects the next (redo) step
        await coordinator.pendingPerform?.value
        undoManager.redo() // must perform the CORRECTED reversal, not the original `op`
        await coordinator.pendingPerform?.value

        #expect(performed == [.wire(staleGuess), .wire(freshAnswer)])
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGUndoCoordinatorTests
```
Expected: build failure — `Performer` still takes `Op`/returns `Bool`, `registerApplied`'s `inverse:` parameter is still `Op`, `WYSIWYGPerformOutcome` doesn't exist.

- [ ] **Step 3: Rewrite `WYSIWYGUndoCoordinator`**

Replace the entire contents of `Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift` with:

```swift
// UndoManager is a Darwin-only Foundation type — see EditUndoCoordinator.swift's header for the
// same rationale; this coordinator compiles out on non-Darwin for the identical reason.
#if canImport(Darwin)
import Foundation

/// What a `WYSIWYGUndoCoordinator.Performer` reports back after replaying one `WYSIWYGReversal`.
public enum WYSIWYGPerformOutcome: Sendable {
    /// The replay was refused (e.g. a version-mismatch conflict) — nothing changed.
    case rejected
    /// The replay landed. `freshInverse`, when non-nil, is the accurate reversal of what was
    /// just performed — computed by the transport against the post-write tree (#1602 item 2).
    /// `nil` means the transport has no better answer than the client-computed guess already
    /// registered as the next undo/redo step (e.g. `StubWYSIWYGHostTransport`, or the rare op
    /// family the sidecar doesn't compute an inverse for) — the existing optimistic registration
    /// is left as-is in that case.
    case applied(freshInverse: WYSIWYGReversal?)
}

/// Bridges applied WYSIWYG ops into a window's `UndoManager` with **real redo** — unlike
/// `EditUndoCoordinator` (git-revert LIFO, no redo), every op ships its own inverse (spec §3.2),
/// so undoing an action re-registers the forward op as the next redo/undo step: standard
/// `UndoManager` usage for a redo-capable client.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Replays one reversal step against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.apply(_:)`'s non-notifying twin (see that type's doc for why it
    /// must not be `submit(_:)` itself), awaited to completion. See `WYSIWYGPerformOutcome` for
    /// what the return value drives: `register`'s optimistic re-registration is corrected on
    /// `.applied(freshInverse:)` and rolled back entirely on `.rejected`.
    public typealias Performer = @MainActor (WYSIWYGReversal) async -> WYSIWYGPerformOutcome

    /// The focused window's undo manager. Weak: the window owns it.
    ///
    /// Deliberately **not** captured by `register(step:redoStep:)`'s registration closure — the
    /// closure re-reads this property each time it needs the manager instead. Capturing the
    /// `UndoManager` instance directly in the closure would create a retain cycle: the closure is
    /// itself held by that same `UndoManager`'s undo stack, and since every fire re-registers the
    /// opposite direction, an entry (and the cycle) is always live after the first edit.
    public weak var undoManager: UndoManager?

    private let perform: Performer

    /// The most-recently-registered `editText`'s block id, session baseline (`previousRuns` — the
    /// design doc says: fixed for a whole `RichTextEditor.enter()` session, see that type's header
    /// comment, so it's identical across every debounced commit in that session), and `Token` —
    /// used by `registerApplied(op:inverse:)` to coalesce a burst of same-session debounced
    /// commits into a single undo entry ("typing coalescing"; #1225 final-review fix wave, Finding
    /// 5). Cleared the instant an undo/redo actually fires (`register(step:redoStep:)`'s handler
    /// below), so coalescing never crosses that boundary.
    private var lastEditTextRegistration: (blockId: BlockId, previousRuns: [RichTextRun], token: Token)?

    /// Per-registration marker object, one per call to `register(step:redoStep:)`. `UndoManager`
    /// doesn't retain targets, so each token is kept alive for exactly as long as its stack entry
    /// exists by its own handler capturing it strongly (see `EditUndoCoordinator.Token` for the
    /// identical rationale). A *unique* token per registration — rather than reusing `self` as
    /// the target — is what makes one specific registration selectively removable via
    /// `removeAllActions(withTarget:)` without discarding every other pending undo/redo step for
    /// this coordinator; see `register(step:redoStep:)`'s rollback/correction paths.
    private final class Token {}

    /// The in-flight `perform` spawned by the most recent undo/redo fire. Exposed for tests
    /// (and any other caller that needs to observe completion), which `await` it to see the
    /// conditional-registration-rollback/-correction behavior deterministically — mirrors
    /// `EditUndoCoordinator.pendingPerform`.
    private(set) var pendingPerform: Task<Void, Never>?

    public init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// Registers one applied op on the undo stack. Call from
    /// `WYSIWYGCanvasController`'s applied-op listener list (`addOpAppliedListener`/
    /// `fireOpApplied`), right after a real, already-confirmed success —
    /// this entry point never calls `perform` itself, it only records the step. No-op when no
    /// `undoManager` is attached.
    ///
    /// `op` stays a plain `Op` — it's the forward direction the user just successfully submitted
    /// against an in-sync model, so its embedded ids are valid at the moment of registration (no
    /// id-drift concern there). `inverse` is a `WYSIWYGReversal` because the UNDO direction is
    /// exactly where #1602 item 2's id-drift bug lives: whenever the applying transport reported a
    /// server-computed `WireInverse` (Task 5), the caller passes `.wire(_:)` here instead of
    /// `.op(WYSIWYGOpInverter.invert(op))`.
    public func registerApplied(op: Op, inverse: WYSIWYGReversal) {
        // Typing coalescing (design doc; #1225 final-review fix wave, Finding 5): without this, a
        // long typing session emitted one undo entry per debounced commit, every one of them
        // sharing the SAME `enter()`-time baseline as `previousRuns` — so N stacked undo entries
        // that don't individually do anything a user would recognize as "one edit."
        //
        // When the incoming op is another `editText` on the SAME block, with the SAME
        // `previousRuns` as the most-recently-registered entry, replace that entry instead of
        // stacking a new one (same `Token`-scoped `removeAllActions(withTarget:)` pattern the
        // rejected-perform rollback below already uses). This is correct, not just convenient: the
        // new `op`'s own `previousRuns` already IS the session's true original baseline (unchanged
        // since `enter()`, since `RichTextEditor.#commit` always builds `previousRuns` from the
        // session's fixed baseline, not the prior debounce tick), so nothing from the replaced
        // registration needs to be preserved — its `inverse` would have restored to that exact
        // same baseline anyway.
        //
        // Comparing `previousRuns` (not just `blockId`) is load-bearing: two genuinely SEPARATE
        // sessions on the same block (edit, click away, come back, edit again) would otherwise
        // still match on `blockId` alone, and blindly replacing would silently truncate undo
        // history — the first session's edit would become unrecoverable through Undo. A second
        // session's `previousRuns` is whatever the first session's LAST commit's `runs` was
        // (`enter()` re-reads the live model at entry), which only coincidentally equals the
        // stored baseline, so this check reliably tells the two cases apart.
        if case .editText(let blockId, _, let previousRuns) = op,
           let last = lastEditTextRegistration, last.blockId == blockId, last.previousRuns == previousRuns {
            undoManager?.removeAllActions(withTarget: last.token)
        }
        let token = register(step: inverse, redoStep: .op(op))
        if case .editText(let blockId, _, let previousRuns) = op, let token {
            lastEditTextRegistration = (blockId, previousRuns, token)
        } else {
            lastEditTextRegistration = nil
        }
    }

    /// Registers `step` as the action a future `undo()`/`redo()` performs. When it fires:
    ///
    /// 1. **Synchronously**, before any `await`, re-registers `redoStep` as the next step in the
    ///    opposite direction (optimistically — see below). This has to happen synchronously:
    ///    `UndoManager.registerUndo` decides whether a registration lands on the undo or redo
    ///    stack from `isUndoing`/`isRedoing` *at the moment it's called*, and both flags revert to
    ///    `false` as soon as this handler's synchronous portion returns — well before an
    ///    unstructured `Task`'s body would actually run, even one with no real suspension inside
    ///    it. Registering only *after* `await`ing `perform` (the natural-looking ordering) always
    ///    lands the registration on the wrong stack in practice — verified empirically: with that
    ///    ordering, `canRedo` never becomes `true` after an undo, in both a bare synchronous
    ///    `Performer` and the real `WYSIWYGCanvasController`-backed one.
    /// 2. Only *then* asynchronously calls `perform(step)` — the actual document mutation.
    ///    - `.rejected`: the optimistic registration from step 1 is now describing a step that
    ///      never happened; it's removed via `removeAllActions(withTarget:)`, scoped to that one
    ///      registration's `Token` so nothing else already on either stack is disturbed.
    ///    - `.applied(freshInverse: someReversal)`: `someReversal` is the ACCURATE reversal of
    ///      what `step` just did — more accurate than the `redoStep` guess the optimistic
    ///      registration used, since it was computed by the transport against the post-write
    ///      tree (#1602 item 2). Remove the optimistic registration and re-register with the
    ///      corrected value in its place, same removal mechanism as the rejection path.
    ///    - `.applied(freshInverse: nil)`: the transport had no better answer — leave the
    ///      optimistic registration exactly as it is (this is the ONLY outcome
    ///      `StubWYSIWYGHostTransport`-backed callers ever produce).
    ///
    /// Explicit group per registration: without one, `registerUndo` throws under
    /// `groupsByEvent = false` ("must begin a group before registering undo") — unit tests and
    /// any other run-loop-free caller set that, since no implicit event group is ever open. Under
    /// the app's default `groupsByEvent = true` this nests harmlessly inside the enclosing event
    /// group, same as `EditUndoCoordinator.registerApplied(_:)`.
    @discardableResult
    private func register(step: WYSIWYGReversal, redoStep: WYSIWYGReversal) -> Token? {
        guard let undoManager else { return nil }
        let token = Token()
        undoManager.beginUndoGrouping()
        // `token` is captured strongly by the handler on purpose — same reason as
        // `EditUndoCoordinator`'s own token capture: `UndoManager` holds its target
        // unsafely-unretained, so the capture pins `token` (and nothing else besides a weak
        // `self`) for exactly as long as this stack entry exists.
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            // Finding 5: an undo/redo just fired — a same-block `editText` commit that arrives
            // after this point must start a fresh undo entry, never coalesce into whatever this
            // fire just put back on top of the stack.
            self.lastEditTextRegistration = nil
            let optimisticallyRegistered = self.register(step: redoStep, redoStep: step)
            self.pendingPerform = Task { @MainActor [weak self] in
                guard let self else { return }
                switch await self.perform(step) {
                case .rejected:
                    if let optimisticallyRegistered {
                        self.undoManager?.removeAllActions(withTarget: optimisticallyRegistered)
                    }
                case .applied(let freshInverse):
                    if let freshInverse, let optimisticallyRegistered {
                        self.undoManager?.removeAllActions(withTarget: optimisticallyRegistered)
                        _ = self.register(step: freshInverse, redoStep: step)
                    }
                }
                _ = token // keep the fired entry's own token referenced; see the capture-list comment above
            }
        }
        // Named while the group is still open — the name attaches to the open group; after
        // `endUndoGrouping` there may be no group left to attach to.
        undoManager.setActionName("Edit")
        undoManager.endUndoGrouping()
        return token
    }
}
#endif
```

- [ ] **Step 4: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGUndoCoordinatorTests
```
Expected: PASS, all 9 tests (7 rewritten + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift Tests/AnglesiteCoreTests/WYSIWYGUndoCoordinatorTests.swift
git commit -m "feat(#1602): self-correcting WYSIWYGReversal undo/redo registration"
```

---

### Task 7: Wire it into `WYSIWYGCanvasController`

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGServerInvertibleTransport`, `WYSIWYGReversal`, `WireInverse` (Task 5), `WYSIWYGPerformOutcome`, `WYSIWYGUndoCoordinator.Performer` (Task 6).

- [ ] **Step 1: Update the two existing tests whose `reported`/listener tuple type changes**

In `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`, `submitAppliesAndReportsInverse` and `sendOpForwardsRealTargetVersion` both declare `var reported: (op: Op, inverse: Op, ...)?` and assert `reported?.inverse == WYSIWYGOpInverter.invert(op)`. Change both to:

```swift
        var reported: (op: Op, inverse: WYSIWYGReversal, model: BlockModel)?
        controller.addOpAppliedListener { op, inverse, model in reported = (op, inverse, model) }
```

(drop `model` from the tuple in `sendOpForwardsRealTargetVersion`, matching its existing `(op: Op, inverse: Op)?` shape — just retype `inverse` there too) and:

```swift
        #expect(reported?.inverse == .op(WYSIWYGOpInverter.invert(op)))
```

respectively (`StubWYSIWYGHostTransport` never conforms to `WYSIWYGServerInvertibleTransport`, so every existing stub-backed test keeps falling back to the plain client-computed `.op(_:)` reversal — this is the expected, unchanged behavior for every test in this file except the one added in Step 5 below).

- [ ] **Step 2: Run to verify failure**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGCanvasControllerTests
```
Expected: build failure — `opAppliedListeners`/`addOpAppliedListener`/`fireOpApplied`/`undoCoordinator`'s `Performer` closure all still use bare `Op`.

- [ ] **Step 3: Update `WYSIWYGCanvasController`**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`, make these changes:

Change the listener storage and registration:

```swift
    private var opAppliedListeners: [(Op, WYSIWYGReversal, BlockModel) -> Void] = []

    func addOpAppliedListener(_ listener: @escaping (Op, WYSIWYGReversal, BlockModel) -> Void) {
        opAppliedListeners.append(listener)
    }

    private func fireOpApplied(_ op: Op, _ inverse: WYSIWYGReversal, _ model: BlockModel) {
        for listener in opAppliedListeners { listener(op, inverse, model) }
    }
```

Change the undo coordinator's `Performer` closure:

```swift
    lazy var undoCoordinator = WYSIWYGUndoCoordinator { [weak self] step in
        guard let self else { return .rejected }
        let (result, freshInverse) = await self.apply(step)
        switch result {
        case .applied:
            return .applied(freshInverse: freshInverse)
        case .rejected:
            return .rejected
        }
    }
```

Replace `submit(_:)`, the private `apply(_:)`, and `sendAndApply(_:)` (the whole block from `submit(_:)` through `sendAndApply(_:)`'s closing brace) with:

```swift
    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let (result, freshInverse) = await apply(.op(op))
        if case .applied(let newModel) = result {
            hasUncommittedOps = true
            fireOpApplied(op, freshInverse ?? .op(WYSIWYGOpInverter.invert(op)), newModel)
        }
        return result
    }

    /// Replays one reversal step against the transport and updates `model` — the shared core
    /// used by `submit(_:)` (wrapping a fresh user-issued `Op`) and `undoCoordinator`'s
    /// `Performer` (replaying whatever `WYSIWYGReversal` is registered for an undo/redo fire).
    /// Does not fire `fireOpApplied`; callers that need the notification do so themselves after
    /// inspecting the result, same division of responsibility `apply(_:)`/`submit(_:)` already
    /// had before #1602.
    private func apply(_ reversal: WYSIWYGReversal) async -> (result: OpResult, freshInverse: WYSIWYGReversal?) {
        switch reversal {
        case .op(let op):
            let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
            return await sendAndApply(envelope)
        case .wire(let inverse):
            return await sendAndApplyServerInverse(inverse)
        }
    }

    /// Sends `envelope` to the transport verbatim and applies the result to `model` — the shared
    /// core of both `apply(_:)`'s `.op` case (which builds a fresh envelope from `model.version`)
    /// and `sendOp(_:)` (the `WYSIWYGHostTransport` conformance below, whose caller — the JS engine
    /// — already computed `targetVersion` and must not have it silently replaced). When `transport`
    /// conforms to `WYSIWYGServerInvertibleTransport` (true for `SidecarWYSIWYGHostTransport`,
    /// false for `StubWYSIWYGHostTransport`), also surfaces the server-computed reversal for the
    /// applied op (#1602 item 2) instead of leaving the caller to fall back to
    /// `WYSIWYGOpInverter.invert` unconditionally.
    private func sendAndApply(_ envelope: OpEnvelope) async -> (result: OpResult, freshInverse: WYSIWYGReversal?) {
        if let invertible = transport as? any WYSIWYGServerInvertibleTransport {
            let (result, serverInverse) = await invertible.sendOpReportingServerInverse(envelope)
            return (await absorb(result), serverInverse.map(WYSIWYGReversal.wire))
        }
        return (await absorb(transport.sendOp(envelope)), nil)
    }

    /// The `WireInverse` counterpart to `sendAndApply(_:)` — replays a server-computed reversal
    /// verbatim via `WYSIWYGServerInvertibleTransport.applyServerInverse(_:requestId:)`, bypassing
    /// `WYSIWYGOpTranslator` entirely. A `.wire` reversal is only ever constructed (Task 6's
    /// `WYSIWYGUndoCoordinator`) from a reply THIS SAME transport produced, and the transport
    /// doesn't change mid-session, so the `as?` cast failing here is defensive, not an expected
    /// path — there's no `Op` to fall back to for a raw wire payload if it somehow did.
    private func sendAndApplyServerInverse(_ inverse: WireInverse) async -> (result: OpResult, freshInverse: WYSIWYGReversal?) {
        guard let invertible = transport as? any WYSIWYGServerInvertibleTransport else {
            return (.rejected(reason: .hostError, message: "transport cannot replay a server-computed inverse", freshModel: nil), nil)
        }
        let (result, serverInverse) = await invertible.applyServerInverse(inverse, requestId: UUID().uuidString)
        return (await absorb(result), serverInverse.map(WYSIWYGReversal.wire))
    }

    /// Applies `result` to `model` (on `.applied`, or on `.rejected` when a `freshModel` came
    /// along for the ride) and re-runs the quality gates — factored out of `sendAndApply(_:)`/
    /// `sendAndApplyServerInverse(_:)` so both share the exact same "model changed" handling
    /// `sendAndApply(_:)` always had (see its pre-#1602 doc comment for why the gates hang off
    /// this funnel rather than the applied-op listener list). Returns `result` unchanged, so
    /// callers can chain `await absorb(...)` directly into their own return expression.
    private func absorb(_ result: OpResult) async -> OpResult {
        switch result {
        case .applied(let newModel):
            model = newModel
            await runQualityGates(model: newModel)
        case .rejected(_, _, let freshModel):
            if let freshModel {
                model = freshModel
                await runQualityGates(model: freshModel)
            }
        }
        return result
    }
```

Finally, update the `WYSIWYGHostTransport` conformance's `sendOp(_:)`:

```swift
    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let (result, freshInverse) = await sendAndApply(envelope)
        if case .applied(let newModel) = result {
            fireOpApplied(envelope.op, freshInverse ?? .op(WYSIWYGOpInverter.invert(envelope.op)), newModel)
        }
        return result
    }
```

- [ ] **Step 4: Run to verify pass**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGCanvasControllerTests
```
Expected: PASS, all existing tests (retyped in Step 1, otherwise unchanged behavior — `StubWYSIWYGHostTransport` never conforms to `WYSIWYGServerInvertibleTransport`, so every one of them still exercises the plain `.op(WYSIWYGOpInverter.invert(...))` fallback path exactly as before).

- [ ] **Step 5: Add one test proving the sidecar path's fresh inverse actually reaches the undo coordinator**

Add to `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` — this needs a fake `WYSIWYGServerInvertibleTransport`; add it as a private helper type in the same file:

```swift
private final class FakeInvertibleTransport: WYSIWYGServerInvertibleTransport, @unchecked Sendable {
    private var model: BlockModel
    var nextServerInverse: WireInverse?

    init(model: BlockModel) {
        self.model = model
    }

    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        await sendOpReportingServerInverse(envelope).result
    }

    func sendOpReportingServerInverse(_ envelope: OpEnvelope) async -> (result: OpResult, serverInverse: WireInverse?) {
        guard let next = StubWYSIWYGHostTransport.applying(envelope.op, to: model) else {
            return (.rejected(reason: .invalidTarget, message: "target block not found", freshModel: nil), nil)
        }
        model = next
        return (.applied(model: next), nextServerInverse)
    }

    func applyServerInverse(_ inverse: WireInverse, requestId: String) async -> (result: OpResult, serverInverse: WireInverse?) {
        (.applied(model: model), nil) // not exercised by this test
    }

    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void { {} }
}

extension WYSIWYGCanvasControllerTests {
    @Test("submit reports a WireInverse from a WYSIWYGServerInvertibleTransport instead of the local guess (#1602 item 2)")
    func submitPrefersServerComputedInverseWhenAvailable() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = FakeInvertibleTransport(model: initial)
        let serverInverse = WireInverse(op: "deleteBlock", component: .object(["nodeId": .string("real-n7")]))
        transport.nextServerInverse = serverInverse
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        var reported: WYSIWYGReversal?
        controller.addOpAppliedListener { _, inverse, _ in reported = inverse }

        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        _ = await controller.submit(op)

        #expect(reported == .wire(serverInverse))
    }
}
```

- [ ] **Step 6: Run to verify pass, then run the full suite and app build**

```bash
scripts/swift-test.sh --package-path . --filter WYSIWYGCanvasControllerTests
scripts/swift-test.sh --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: all PASS, BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1602): wire server-computed undo/redo reversals into WYSIWYGCanvasController"
```

---

### Task 8: Full verification + manual smoke test

**Files:** none (verification task)

- [ ] **Step 1: Run everything**

```bash
scripts/swift-test.sh --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test && cd -
```
Expected: all green. The JS suite should be unaffected (Global Constraints), but run it anyway — it's part of `CONTRIBUTING.md`'s required checks and confirms this plan's "no JS change needed" assumption held.

- [ ] **Step 2: Manual smoke test** (no GUI automation available in a headless session — this step is for whoever has an interactive Mac session; per `CONTRIBUTING.md` ▸ Testing / `docs/testing-macos-app.md`)

Launch the app, open a real `.anglesite` site with at least one page containing plain-text content and one manifest-registered component block, toggle Site ▸ Edit Page, and confirm:

1. Edit a paragraph's text, then ⌘Z — the text reverts to its ORIGINAL content, not empty (item 1).
2. Insert a block, then ⌘Z then ⇧⌘Z (redo) — the block is removed then reinserted correctly, with no "node not found"-style failure (item 2's common case).
3. Duplicate an existing manifest-registered component block (e.g. via ⌘D) and confirm the site's dev-server preview doesn't show a broken-import error, and the generated `.astro` source has a correct `import` path (item 3).
4. Undo several edits in a row (3+), interleaved with at least one redo, watching for any edit that silently fails to apply or reports an unexpected error — this is the residual-gap case named in this plan's design decision 3; a failure here should be logged as a new, narrower follow-up issue rather than blocking this PR, unless it reproduces the ORIGINAL reported bug (undo restoring to empty content, or addressing a nonexistent node) rather than a new edge case.

- [ ] **Step 3: Record the smoke-test result in the PR body's Test plan section** — this plan's PR cannot claim "manual smoke: done" without this step actually having been run by a human with the app open.

---

## Self-review

**Spec coverage:** Task 1 covers item 1 (text-edit undo baseline). Tasks 2-3 cover item 3 (component-insert manifest path): identity plumbing (adapter → `BlockNode`/`BlockNodeContent` → inverter → duplicate) then the translator's wire-form preference. Tasks 4-7 cover item 2 (undo/redo id-drift): decoding the full server inverse, the new transport capability, the undo coordinator's self-correcting registration, and wiring it into the canvas controller. Task 8 is full verification + the manual smoke test the design doc convention requires for anything touching the live preview. All three "Design decisions" gaps (lossy rich-text baseline, unwired manifest palette, bounded undo/redo self-correction) are named explicitly with a pointer to why, not silently left as surprises.

**Placeholder scan:** No bare "TODO"/"handle appropriately" steps. Every task's code is the actual diff, not a description of one. The two named residual gaps (design decisions 1 and 3) are explicit, reasoned simplifications with a stated boundary — matching this codebase's own convention (see `WYSIWYGOpTranslator.stringValue`'s doc comment for the same pattern) — not silent TBDs.

**Type consistency:** `BlockNode.manifestName`/`BlockNodeContent.manifestName` (Task 2) are threaded consistently through the adapter, inverter, stub transport, and `duplicateSelectedBlock` — verified by re-reading each call site's full argument list. `WireInverse`/`WYSIWYGReversal` (Task 5) are used with matching case names (`.op`/`.wire`) and field names (`op`/`component`) across `WYSIWYGHostTransport.swift`, `SidecarWYSIWYGHostTransport.swift`, `WYSIWYGUndoCoordinator.swift`, and `WYSIWYGCanvasController.swift`. `WYSIWYGPerformOutcome`'s two cases (`.rejected`, `.applied(freshInverse:)`) match exactly between its declaration (Task 6) and every call site that switches on it (Task 6's coordinator, Task 7's `undoCoordinator` closure).
