# WYSIWYG Sidecar-Backed Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `StubWYSIWYGHostTransport` (the in-memory fixture the WYSIWYG editor's Mac host layer — slices 2-5, all merged — was deliberately built against) with a real transport backed by the sidecar's `get_page_model` tool and its six new `apply_edit` ops, so the editor round-trips through actual source files instead of an in-memory model that resets on every launch.

**Architecture:** A new `SidecarWYSIWYGHostTransport` conforms to the existing `WYSIWYGHostTransport` protocol — the seam the design doc already named as the swap point. It composes three pieces, two of which are new: (1) a **wire translator** that turns the app's `Op` enum into the sidecar's `apply_edit` component-edit JSON (the two shapes don't match field-for-field — the sidecar's ops address nodes by `parentId`+`index` into a single ordered child list, not `Op`'s `slot`-keyed dict), (2) a **model adapter** that turns the sidecar's `PageModel.Node` tree (already fetched elsewhere in this app via `PageModelClient`, for #768) into this feature's flat, ID-indexed `BlockModel`, and (3) the existing `EditRouter`/`PageModelClient` plumbing, unchanged.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), the existing `AnglesiteCore` MCP client stack (`MCPClient`, `PageModelClient`, `MCPApplyEditRouter`).

## Global Constraints

- **No new dependencies** — everything here is Foundation + the existing `AnglesiteCore` types. Per `CONTRIBUTING.md`, new dependencies need explicit approval in an issue first; none are needed.
- **The sidecar op names are `insertBlock`/`moveBlock`/`deleteBlock`/`setProp`/`editText`/`setDesignToken`, dispatched through the *existing* `apply_edit` tool** — they are not separate MCP tools. `insertBlock`/`setProp` reuse the exact resolver as `insert-node`/`set-attr`; only `moveBlock`/`deleteBlock`/`editText`/`setDesignToken` need new wire-op constants and builders (this repo already added `insertBlock`'s `manifestBlock`-only variant for #768; it's missing the `node:`-based variant this feature also needs).
- **`baseVersion`/model `version` is a whole-file content hash**: `"sha256:" + sha256(source).hexPrefix(12)`, computed server-side in `server/file-version.mjs`. Treat it as an opaque string on the Swift side — never parse or reconstruct it locally.
- **The sidecar does not piggyback a fresh page model onto an `apply_edit` reply for these ops** (that piggyback exists only for Component Editor CSS ops). A successful op requires a *separate* `get_page_model` re-fetch to get the post-write model. This is a real, deliberate two-round-trip cost, not a bug — a caching optimization is out of scope here (see "Out of scope" below).
- **Swift Testing only** (`@Suite`/`@Test`/`#expect`) — every existing WYSIWYG test file uses it, none use XCTest. Match that.
- **Run before every commit**: `swift test --package-path .` and (if `Sources/AnglesiteApp` changed) `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, per `CONTRIBUTING.md` ▸ Testing.

## Design decisions baked into this plan (read before objecting to a task's shape)

1. **Superseded 2026-09-02** — see `docs/superpowers/plans/2026-09-02-wysiwyg-undo-correctness-and-component-insert.md`, which reverses this decision for undo/redo (item 2). **Server-computed `inverse` is NOT consumed in this plan.** `OpResult` (the transport's return type) has no `inverse` field today — `WYSIWYGCanvasController` always computes the inverse locally via `WYSIWYGOpInverter.invert(op)`, regardless of which transport is wired in (`WYSIWYGCanvasController.swift:109,358`). Swapping the stub for a real transport doesn't change that. Consuming the sidecar's server-computed `inverse` (anglesite-skills#435's `EditReply`-equivalent `inverse: {op, component}` field) instead of the local pure inverter — which would also require plumbing around its two documented v1 gaps (pruned-import restoration, whitespace fidelity on multi-line markup) — is real, separable follow-up work. It is **explicitly out of scope here**; file it as a follow-up issue once this lands.
2. **The flat `BlockModel.blocks` dict represents every `PageModel.Node`, not just manifest-registered block instances.** The wire protocol's `parentId`/`index` addressing has no notion of "only components are targetable" — an owner can insert into a plain `<main>` wrapper, and `moveBlock`'s `newParentId` needs to resolve to *some* node ID whether or not that node happens to be a manifest-registered block. `BlockKind` gets two new cases (`element`, `fragment`) beyond its current `astro`/`custom-element`/`text` to hold non-block wrapper nodes; `slot`/`expression` nodes collapse to `.element` (there is no other structural difference this feature needs from them yet).
3. **Named slots collapse to a single `"default"` key.** `BlockNode.slots: [String: [BlockId]]` exists to hold each node's children in document order; the wire protocol has no named-slot addressing (`moveBlock`/`insertBlock` take `parentId`+`index`, not `parentId`+`slot`+`index` — that `slot` field is purely an app-side `Op`/`BlockModel` construct from when this was speculatively designed ahead of the real backend). The adapter always uses `"default"` as the single slot key. A component's *real* declared slot names (e.g. "header", "footer") are separately available as `BlockInfo.slots` for any future UI that wants to let an owner target a specific slot — reconciling that into `BlockNode.slots` itself is out of scope.
4. **On a fetch/apply failure, `enterEditMode` does not mount the canvas.** The design spec's "never a blank webview" principle (§9) is about the *canvas surface* once mounted; this plan does not add a new toast/banner affordance for the pre-mount fetch failure — it logs via `LogCenter` (repo convention: "logs are sacred") and leaves `wysiwygCanvas` nil, so the Edit Page toggle simply doesn't turn on. Adding a user-visible failure surface for this path is a reasonable one-task follow-up, explicitly not this plan's job.

## Out of scope (this plan)

- Consuming the server-computed `inverse` (decision 1 above).
- A caching/optimistic-update layer to avoid the double round-trip per op.
- Any UI for the pre-mount fetch-failure path beyond a log line (decision 4 above).
- The two sidecar-side v1 gaps (pruned import, whitespace fidelity) — irrelevant here since this plan never reads the server's `inverse`.
- Slice 4 PR2/PR3 (native panels, polish/accessibility — tracked separately as #1588/#1589).

---

### Task 0: Cut an `anglesite-skills` release tag (prerequisite — not agentic, flag for a human)

**This step cannot be done by an implementing subagent** — it's a release action in a sibling repo (`Anglesite/anglesite-skills`), outside this worktree, and per `CONTRIBUTING.md` ▸ "Paired PRs" the sidecar ships first in a tagged release before the app PR consumes it.

- [ ] **Step 1: Confirm what's on `main` since the last tag**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/anglesite-skills
git fetch origin
git log v1.9.0..origin/main --oneline
```
Confirm PR #435 (`29ecc49`) and anything that landed after it look release-shaped (no in-progress/WIP commits at the tip).

- [ ] **Step 2: Cut and push the tag**

```bash
npm version minor --no-git-tag-version   # bumps package.json to e.g. 1.10.0
git add package.json package-lock.json
git commit -m "chore: release v1.10.0"
git tag v1.10.0
git push origin main --tags
```
(Match whatever this repo's actual release process already is — check for a `CHANGELOG.md` or release script first; the above is the minimum if none exists.)

- [ ] **Step 3: Re-vendor the container image in this app repo**

Once the tag is pushed, the app's container image needs to pick it up — this repo's own vendoring path (`scripts/vendor-container-image.sh` per `CONTRIBUTING.md` ▸ "unsupported-op" hint elsewhere in this codebase). Do this as part of Task 5 below (it needs the new ops to exist in the image for manual/e2e testing anyway), not redundantly here.

**Local development for Tasks 1-4 below does not need this tag** — `ANGLESITE_PLUGIN_PATH` pointed at the sidecar checkout by path (already the documented pattern for the MCP/apply-edit e2e tests, per `CONTRIBUTING.md` ▸ Testing) exercises `main` directly. Only defer Task 0 if you want to start coding immediately; it must land before this feature's final PR merges.

---

### Task 1: Wire-op translator — extend `EditMessage.Op` and `ComponentStructureEditBuilder`

**Files:**
- Modify: `Sources/AnglesiteCore/EditMessage.swift` (add op-name constants, `EditMessage.Op` enum-like namespace at lines 25-82)
- Modify: `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift` (add builders, alongside the existing `insertNode`/`insertBlock`/`moveNode`/`removeNode`/`setAttr`)
- Test: `Tests/AnglesiteCoreTests/ComponentStructureEditBuilderTests.swift` (create if it doesn't already exist — check first: `find Tests -iname "*ComponentStructureEditBuilder*"`)

**Interfaces:**
- Produces: `EditMessage.Op.moveBlock/.deleteBlock/.editText/.setDesignToken` (new string constants); `ComponentStructureEditBuilder.moveBlock(id:path:baseVersion:nodeId:newParentId:newIndex:) -> EditMessage`, `.deleteBlock(id:path:baseVersion:nodeId:) -> EditMessage`, `.editText(id:path:baseVersion:textNodeId:runs:) -> EditMessage`, `.setDesignToken(id:path:baseVersion:token:tokenValue:) -> EditMessage`, and `.insertBlockNode(id:path:baseVersion:parentId:index:node:) -> EditMessage` (the `node:`-based sibling of the existing `manifestBlock`-only `insertBlock`, needed when translating an `Op.insertBlock` whose `BlockNodeContent` isn't a manifest reference).
- Consumes: nothing new — `EditMessage`, `JSONValue` already exist.

- [ ] **Step 1: Write the failing tests for the four straightforward builders**

```swift
import Testing
@testable import AnglesiteCore

@Suite("ComponentStructureEditBuilder — WYSIWYG ops")
struct ComponentStructureEditBuilderWYSIWYGTests {
    @Test func moveBlockBuildsWireShape() {
        let message = ComponentStructureEditBuilder.moveBlock(
            id: "req-1", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            nodeId: "n5", newParentId: "n2", newIndex: 0)
        #expect(message.op == "moveBlock")
        #expect(message.path == "src/pages/index.astro")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component["newParentId"] == .string("n2"))
        #expect(component["newIndex"] == .int(0))
        #expect(component["baseVersion"] == .string("sha256:abc123def456"))
    }

    @Test func deleteBlockBuildsWireShape() {
        let message = ComponentStructureEditBuilder.deleteBlock(
            id: "req-2", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456", nodeId: "n5")
        #expect(message.op == "deleteBlock")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component.count == 3) // path, baseVersion, nodeId — no extras
    }

    @Test func editTextBuildsWireShape() {
        let runs = [RichTextRun(kind: .text, text: "Hi ", href: nil), RichTextRun(kind: .strong, text: "there", href: nil)]
        let message = ComponentStructureEditBuilder.editText(
            id: "req-3", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            textNodeId: "n5", runs: runs)
        #expect(message.op == "editText")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["textNodeId"] == .string("n5"))
        guard case .array(let wireRuns)? = component["runs"] else {
            Issue.record("expected runs array"); return
        }
        #expect(wireRuns.count == 2)
    }

    @Test func setDesignTokenBuildsWireShape() {
        let message = ComponentStructureEditBuilder.setDesignToken(
            id: "req-4", path: "src/styles/global.css", baseVersion: "sha256:abc123def456",
            token: "--color-primary", tokenValue: "#111111")
        #expect(message.op == "setDesignToken")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["token"] == .string("--color-primary"))
        #expect(component["tokenValue"] == .string("#111111"))
    }

    @Test func insertBlockNodeBuildsWireShapeForRawMarkup() {
        let message = ComponentStructureEditBuilder.insertBlockNode(
            id: "req-5", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            parentId: "n2", index: 1, node: .raw(markup: "<p id=\"gone\">b</p>"))
        #expect(message.op == "insertBlock")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        guard case .object(let node)? = component["node"] else {
            Issue.record("expected node object"); return
        }
        #expect(node["kind"] == .string("raw"))
        #expect(node["markup"] == .string("<p id=\"gone\">b</p>"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path . --filter ComponentStructureEditBuilderWYSIWYGTests
```
Expected: build failure — `moveBlock`/`deleteBlock`/`editText`/`setDesignToken`/`insertBlockNode` don't exist yet, and `EditMessage.Op.moveBlock` etc. don't exist.

- [ ] **Step 3: Add the four op-name constants + a `NodeSpec.raw` case**

In `Sources/AnglesiteCore/EditMessage.swift`, inside `public enum Op` (after the existing `insertBlock` constant at line 58):

```swift
        /// `"moveBlock"` — reparent/reorder an existing node (WYSIWYG editor). Carries a
        /// `component` payload.
        public static let moveBlock = "moveBlock"
        /// `"deleteBlock"` — delete a node and its subtree (WYSIWYG editor). Carries a
        /// `component` payload.
        public static let deleteBlock = "deleteBlock"
        /// `"editText"` — replace a text node's rich-text runs (WYSIWYG editor honest-runs
        /// inline editing). Carries a `component` payload.
        public static let editText = "editText"
        /// `"setDesignToken"` — patch a CSS custom property in `global.css`'s light `:root`
        /// block (WYSIWYG editor). Carries a `component` payload; `path` is always
        /// `"src/styles/global.css"` — the sidecar hardcodes and validates that target.
        public static let setDesignToken = "setDesignToken"
```

In `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift`, extend `NodeSpec` (after the existing `.slot` case, line 19) with a fourth case for raw markup — needed when translating `Op.insertBlock`/`deleteBlock`'s inverse, which carries already-serialized content rather than a fresh tag name:

```swift
        /// Pre-serialized markup, inserted verbatim — used when reinstating a block whose
        /// content the app already has (e.g. undo of a delete), not when creating a brand-new
        /// empty node.
        case raw(markup: String)
```
and its `jsonValue` case:
```swift
            case .raw(let markup):
                return .object(["kind": .string("raw"), "markup": .string(markup)])
```

- [ ] **Step 4: Add the five builder functions**

Append to `Sources/AnglesiteCore/ComponentStructureEditBuilder.swift`, following the existing builders' exact shape:

```swift
    /// Builds the `moveBlock` message: reparent/reorder `nodeId` under `newParentId` at
    /// `newIndex`. Wire-identical to `moveNode`'s payload — a distinct name because the WYSIWYG
    /// engine and the Component Editor are separate protocol-facing callers of the same resolver.
    public static func moveBlock(
        id: String, path: String, baseVersion: String,
        nodeId: String, newParentId: String, newIndex: Int
    ) -> EditMessage {
        EditMessage(
            id: id, path: path, selector: nil, op: EditMessage.Op.moveBlock,
            component: .object([
                "path": .string(path), "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId), "newParentId": .string(newParentId), "newIndex": .int(newIndex),
            ]),
            value: nil)
    }

    /// Builds the `deleteBlock` message: delete `nodeId` and its whole subtree. Wire-identical to
    /// `removeNode`'s payload.
    public static func deleteBlock(id: String, path: String, baseVersion: String, nodeId: String) -> EditMessage {
        EditMessage(
            id: id, path: path, selector: nil, op: EditMessage.Op.deleteBlock,
            component: .object(["path": .string(path), "baseVersion": .string(baseVersion), "nodeId": .string(nodeId)]),
            value: nil)
    }

    /// Builds the `editText` message: replace `textNodeId`'s rich-text runs. `runs` encodes as
    /// `RichTextRun`'s own `Codable` conformance via `JSONValue.from` — kind/text/href/children.
    public static func editText(id: String, path: String, baseVersion: String, textNodeId: String, runs: [RichTextRun]) -> EditMessage {
        let encoder = JSONEncoder()
        let runsData = (try? encoder.encode(runs)) ?? Data()
        let runsValue = (try? JSONSerialization.jsonObject(with: runsData)).flatMap(JSONValue.from) ?? .array([])
        return EditMessage(
            id: id, path: path, selector: nil, op: EditMessage.Op.editText,
            component: .object([
                "path": .string(path), "baseVersion": .string(baseVersion),
                "textNodeId": .string(textNodeId), "runs": runsValue,
            ]),
            value: nil)
    }

    /// Builds the `setDesignToken` message: patch `token`'s value in `global.css`'s light
    /// `:root` block. `path` must be `"src/styles/global.css"` — the sidecar hardcodes and
    /// validates this exact target, so callers always pass that literal, not the edited page's
    /// path.
    public static func setDesignToken(id: String, path: String, baseVersion: String, token: String, tokenValue: String) -> EditMessage {
        EditMessage(
            id: id, path: path, selector: nil, op: EditMessage.Op.setDesignToken,
            component: .object([
                "path": .string(path), "baseVersion": .string(baseVersion),
                "token": .string(token), "tokenValue": .string(tokenValue),
            ]),
            value: nil)
    }

    /// Builds an `insertBlock` message from an explicit `NodeSpec` rather than a manifest name —
    /// the sibling of `insertBlock(id:path:baseVersion:parentId:index:manifestBlock:)` above, for
    /// callers that already have concrete node content (e.g. reinstating raw markup on undo, or
    /// inserting a plain element/slot the manifest doesn't know about).
    public static func insertBlockNode(id: String, path: String, baseVersion: String, parentId: String, index: Int, node: NodeSpec) -> EditMessage {
        EditMessage(
            id: id, path: path, selector: nil, op: EditMessage.Op.insertBlock,
            component: .object([
                "path": .string(path), "baseVersion": .string(baseVersion),
                "parentId": .string(parentId), "index": .int(index), "node": node.jsonValue,
            ]),
            value: nil)
    }
```

Check `JSONValue.from(_:)`'s exact signature before using it (`grep -n "static func from" Sources/AnglesiteCore/MCPClient.swift` or wherever `JSONValue` lives) — adjust the `editText` builder's encoding glue if the real signature differs from `(Any) -> JSONValue?`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
swift test --package-path . --filter ComponentStructureEditBuilderWYSIWYGTests
```
Expected: PASS, all 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/EditMessage.swift Sources/AnglesiteCore/ComponentStructureEditBuilder.swift Tests/AnglesiteCoreTests/ComponentStructureEditBuilderWYSIWYGTests.swift
git commit -m "feat(#1222): add wire-op builders for moveBlock/deleteBlock/editText/setDesignToken"
```

---

### Task 2: `Op` → wire `EditMessage` translator

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpTranslator.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGOpTranslatorTests.swift`

**Interfaces:**
- Consumes: `Op` (`WYSIWYGOps.swift:127-134`), `Task 1`'s builders (`ComponentStructureEditBuilder.moveBlock`/`.deleteBlock`/`.editText`/`.setDesignToken`/`.insertBlockNode`, plus the existing `.insertBlock` manifest-name builder and `.setAttr`), `EditMessage`.
- Produces: `WYSIWYGOpTranslator.translate(_ op: Op, requestId: String, path: String, baseVersion: String) -> EditMessage` — used by Task 4's transport.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGOpTranslator")
struct WYSIWYGOpTranslatorTests {
    @Test func translatesInsertBlockToRawNodeInsert() {
        let content = BlockNodeContent(
            kind: .astro, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: "n2", slot: "default", index: 1, newId: "n7", block: content)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-1", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "insertBlock")
        guard case .object(let component)? = message.component, case .object(let node)? = component["node"] else {
            Issue.record("expected component.node object"); return
        }
        #expect(node["kind"] == .string("raw"))
    }

    @Test func translatesMoveBlockDroppingSlotNames() {
        let op = Op.moveBlock(blockId: "n5", fromParentId: "n2", fromSlot: "default", fromIndex: 0, toParentId: "n3", toSlot: "default", toIndex: 2)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-2", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "moveBlock")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component["newParentId"] == .string("n3"))
        #expect(component["newIndex"] == .int(2))
        #expect(component["fromSlot"] == nil) // slot names never reach the wire
    }

    @Test func translatesDeleteBlock() {
        let op = Op.deleteBlock(parentId: "n2", slot: "default", index: 0, blockId: "n5", block: BlockNode(id: "n5", kind: .astro, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-3", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "deleteBlock")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["nodeId"] == .string("n5"))
    }

    @Test func translatesSetProp() {
        let op = Op.setProp(blockId: "n5", propName: "title", value: .string("New"), previousValue: .string("Old"))
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-4", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "set-attr") // reuses the existing Component Editor resolver
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["name"] == .string("title"))
        #expect(component["value"] == .string("New"))
    }

    @Test func translatesEditText() {
        let op = Op.editText(blockId: "n5", runs: [RichTextRun(kind: .text, text: "hi")], previousRuns: [])
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-5", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "editText")
    }

    @Test func translatesSetDesignTokenAlwaysTargetsGlobalCSS() {
        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-6", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.path == "src/styles/global.css") // NOT the page path passed in
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --package-path . --filter WYSIWYGOpTranslatorTests
```
Expected: build failure, `WYSIWYGOpTranslator` doesn't exist.

- [ ] **Step 3: Implement the translator**

```swift
import Foundation

/// Translates the WYSIWYG engine's `Op` (`WYSIWYGOps.swift`) into the sidecar's `apply_edit`
/// wire format via `ComponentStructureEditBuilder`. The two shapes don't match field-for-field —
/// see `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s "Design
/// decisions" section for why `slot` names are dropped and `setDesignToken` retargets its path.
public enum WYSIWYGOpTranslator {
    public static func translate(_ op: Op, requestId: String, path: String, baseVersion: String) -> EditMessage {
        switch op {
        case .insertBlock(let parentId, _, let index, _, let block):
            return ComponentStructureEditBuilder.insertBlockNode(
                id: requestId, path: path, baseVersion: baseVersion,
                parentId: parentId, index: index, node: nodeSpec(for: block))

        case .deleteBlock(let parentId, _, _, let blockId, _):
            _ = parentId // the wire op addresses purely by nodeId; parentId is app-side bookkeeping only
            return ComponentStructureEditBuilder.deleteBlock(
                id: requestId, path: path, baseVersion: baseVersion, nodeId: blockId)

        case .moveBlock(let blockId, _, _, _, let toParentId, _, let toIndex):
            return ComponentStructureEditBuilder.moveBlock(
                id: requestId, path: path, baseVersion: baseVersion,
                nodeId: blockId, newParentId: toParentId, newIndex: toIndex)

        case .setProp(let blockId, let propName, let value, _):
            return ComponentStructureEditBuilder.setAttr(
                id: requestId, path: path, baseVersion: baseVersion,
                nodeId: blockId, name: propName, value: Self.stringValue(value))

        case .editText(let blockId, let runs, _):
            return ComponentStructureEditBuilder.editText(
                id: requestId, path: path, baseVersion: baseVersion, textNodeId: blockId, runs: runs)

        case .setDesignToken(let tokenName, let value, _):
            // The sidecar hardcodes and validates src/styles/global.css as setDesignToken's only
            // valid target (design-token-edit.mjs) — always retarget, ignore the page `path` arg.
            return ComponentStructureEditBuilder.setDesignToken(
                id: requestId, path: "src/styles/global.css", baseVersion: baseVersion,
                token: tokenName, tokenValue: value)
        }
    }

    /// `setProp`'s wire `value` is a plain optional string (`set-attr`'s existing contract) —
    /// `PropValue` is richer (numbers/bools/objects/arrays) than the wire currently accepts for
    /// this op family. Non-string values stringify; `.null` removes the attribute, matching
    /// `setAttr`'s existing `value: nil` convention.
    private static func stringValue(_ value: PropValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        case .object, .array: return nil // not representable on this wire op; see follow-up note below
        }
    }

    private static func nodeSpec(for block: BlockNodeContent) -> ComponentStructureEditBuilder.NodeSpec {
        switch block.kind {
        case .astro, .customElement:
            return .component(tag: block.componentName, componentPath: block.componentName)
        case .text:
            return .element(tag: "span") // no dedicated text-node insert on the wire; a follow-up
        }
    }
}
```

`stringValue`'s `.object`/`.array` case and `nodeSpec`'s `.text` case are honest, narrow gaps (not silently wrong — `.object`/`.array` values are dropped rather than corrupted, and inserting a bare text block degrades to an empty `<span>` rather than crashing). Leave the code comments in place; do not "fix" them speculatively without a real reproduction — flag as follow-up if hit in practice.

- [ ] **Step 4: Run to verify pass**

```bash
swift test --package-path . --filter WYSIWYGOpTranslatorTests
```
Expected: PASS, all 6 tests. If `setAttr`'s value stringification test fails because `setProp`'s wire `value` field actually needs to preserve JSON types (check `server/component-structure-edit.mjs`'s `applySetAttr` if in doubt), adjust `stringValue` — this is exactly the kind of wire-shape assumption worth double-checking against the sidecar checkout at `/Users/dwk/Developer/github.com/Anglesite/anglesite-skills` before trusting this plan's guess.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpTranslator.swift Tests/AnglesiteCoreTests/WYSIWYGOpTranslatorTests.swift
git commit -m "feat(#1222): translate WYSIWYG Op enum to apply_edit wire format"
```

---

### Task 3: `PageModel.Node` → `BlockModel` adapter

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift`
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift` — extend `BlockKind` with `.element`/`.fragment` (design decision 2)
- Test: `Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift`

**Interfaces:**
- Consumes: `PageModel`/`PageModel.Node` (`PageModel.swift`), `BlockModel`/`BlockNode`/`BlockKind` (`WYSIWYGOps.swift`).
- Produces: `PageModelBlockAdapter.adapt(_ pageModel: PageModel) -> BlockModel` — used by Task 4's transport.

- [ ] **Step 1: Extend `BlockKind`**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`, change:
```swift
public enum BlockKind: String, Codable, Sendable {
    case astro
    case customElement = "custom-element"
    case text
}
```
to:
```swift
public enum BlockKind: String, Codable, Sendable {
    case astro
    case customElement = "custom-element"
    case text
    /// A plain HTML element with no block-manifest registration — a wrapper/container node
    /// that's still a valid `insertBlock`/`moveBlock` target even though it's not itself a
    /// theme-authored block. Added for the sidecar-backed transport (#1222); the JS engine side
    /// (`JS/wysiwyg-engine/src/types.ts`) needs the matching case added in lockstep — check it
    /// compiles against the wire string `"element"` before assuming parity.
    case element
    /// The page's synthetic fragment root, or any nested fragment. Never itself editable, but
    /// still addressable as a `parentId`.
    case fragment
}
```

- [ ] **Step 2: Write the failing adapter tests**

```swift
import Testing
@testable import AnglesiteCore

@Suite("PageModelBlockAdapter")
struct PageModelBlockAdapterTests {
    @Test func adaptsFlatTreeWithOneBlock() {
        let pageModel = PageModel(
            version: "sha256:abc123def456",
            path: "src/pages/index.astro",
            tree: .init(
                id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 100), loc: nil, text: nil,
                children: [
                    .init(
                        id: "n1", kind: .element, tag: "main", attrs: [], span: .init(start: 10, end: 90), loc: nil, text: nil,
                        children: [
                            .init(
                                id: "n2", kind: .component, tag: "Hcard", attrs: [.init(name: "name", value: "Ada")],
                                span: .init(start: 20, end: 80), loc: nil, text: nil, children: [],
                                block: .init(manifestPath: "src/components/Hcard.astro", name: "H-Card", description: "", icon: nil, slots: [])),
                        ],
                        block: nil),
                ],
                block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.path == "src/pages/index.astro")
        #expect(model.version == "sha256:abc123def456")
        #expect(model.rootIds == ["n1"])
        #expect(model.blocks.count == 3) // n0, n1, n2 all present — every node, not just blocks

        let main = try! #require(model.blocks["n1"])
        #expect(main.kind == .element)
        #expect(main.slots["default"] == ["n2"])

        let hcard = try! #require(model.blocks["n2"])
        #expect(hcard.kind == .astro)
        #expect(hcard.componentName == "Hcard")
        #expect(hcard.props["name"] == .string("Ada"))
        #expect(hcard.sourceSpan == [20, 80])
    }

    @Test func adaptsNonComponentNodeToElementKind() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil, children: [], block: nil))
        let model = PageModelBlockAdapter.adapt(pageModel)
        let root = try! #require(model.blocks["n0"])
        #expect(root.kind == .fragment)
    }

    @Test func missingSpanBoundsDefaultToZero() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [], block: nil))
        let model = PageModelBlockAdapter.adapt(pageModel)
        #expect(model.blocks["n0"]?.sourceSpan == [0, 0])
    }
}
```

- [ ] **Step 3: Run to verify failure**

```bash
swift test --package-path . --filter PageModelBlockAdapterTests
```
Expected: build failure, `PageModelBlockAdapter` doesn't exist.

- [ ] **Step 4: Implement the adapter**

```swift
import Foundation

/// Adapts the sidecar's `get_page_model` tree (`PageModel.Node`) into this feature's flat,
/// ID-indexed `BlockModel` (`WYSIWYGOps.swift`). See
/// `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s "Design decisions"
/// section for why every node (not just manifest-registered blocks) becomes a `BlockNode`, and
/// why all children collapse into a single `"default"` slot key.
public enum PageModelBlockAdapter {
    public static func adapt(_ pageModel: PageModel) -> BlockModel {
        var blocks: [BlockId: BlockNode] = [:]
        walk(pageModel.tree, into: &blocks)
        return BlockModel(
            path: pageModel.path,
            version: pageModel.version,
            rootIds: pageModel.tree.children.map(\.id),
            blocks: blocks)
    }

    private static func walk(_ node: PageModel.Node, into blocks: inout [BlockId: BlockNode]) {
        var props: [String: PropValue] = [:]
        for attr in node.attrs {
            props[attr.name] = attr.value.map(PropValue.string) ?? .null
        }
        blocks[node.id] = BlockNode(
            id: node.id,
            kind: blockKind(for: node),
            componentName: node.tag ?? "",
            props: props,
            slots: node.children.isEmpty ? [:] : ["default": node.children.map(\.id)],
            sourceSpan: [node.span.start ?? 0, node.span.end ?? 0],
            richText: nil) // rich-text runs come from a dedicated read, not the page-model tree; see Task 5's caveat
        for child in node.children {
            walk(child, into: &blocks)
        }
    }

    private static func blockKind(for node: PageModel.Node) -> BlockKind {
        if node.block != nil { return .astro } // manifest-registered — the only case where "astro"/"custom-element" actually matters downstream; refine to .customElement if `node.block` ever carries a kind flag
        switch node.kind {
        case .fragment: return .fragment
        case .text: return .text
        case .element, .component, .slot, .expression: return .element
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

```bash
swift test --package-path . --filter PageModelBlockAdapterTests
```
Expected: PASS, all 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift Sources/AnglesiteCore/WYSIWYG/PageModelBlockAdapter.swift Tests/AnglesiteCoreTests/PageModelBlockAdapterTests.swift
git commit -m "feat(#1222): adapt PageModel tree into the WYSIWYG engine's flat BlockModel"
```

---

### Task 4: `SidecarWYSIWYGHostTransport`

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/SidecarWYSIWYGHostTransport.swift`
- Test: `Tests/AnglesiteCoreTests/SidecarWYSIWYGHostTransportTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGHostTransport` protocol (`WYSIWYGHostTransport.swift:7-17`), `PageModelClient.fetch(path:)` (`PageModelClient.swift:56`), `EditRouter.apply(_:)` (`EditRouter.swift:119`), `WYSIWYGOpTranslator.translate(...)` (Task 2), `PageModelBlockAdapter.adapt(...)` (Task 3).
- Produces: `SidecarWYSIWYGHostTransport(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter)`, conforming to `WYSIWYGHostTransport` — used by Task 5's `PreviewModel` wiring.

- [ ] **Step 1: Write the failing tests using fake `EditRouter`/`PageModelClient` seams**

```swift
import Testing
@testable import AnglesiteCore

@Suite("SidecarWYSIWYGHostTransport")
struct SidecarWYSIWYGHostTransportTests {
    struct FakeEditRouter: EditRouter {
        let reply: EditReply
        func apply(_ message: EditMessage) async -> EditReply { reply }
    }

    private func emptyPageModel(version: String) -> PageModel {
        PageModel(version: version, path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0), loc: nil, text: nil, children: [], block: nil))
    }

    @Test func appliedOpRefetchesAndAdaptsFreshModel() async {
        let pageModelClient = PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh111111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-1", status: .applied, message: nil))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter)

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-1", targetVersion: "sha256:stale000000", op: op))

        guard case .applied(let model) = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(model.version == "sha256:fresh111111")
    }

    @Test func staleReasonMapsToVersionMismatch() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            MCPClient.ToolCallResult(content: [], isError: false) // never reached — apply fails first
        })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-2", status: .failed, message: "stale", reason: "stale"))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter)

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-2", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, _, _) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .versionMismatch)
    }

    @Test func otherFailureReasonMapsToHostError() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in MCPClient.ToolCallResult(content: [], isError: false) })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-3", status: .failed, message: "not found", reason: "invalid-input"))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter)

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-3", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, let message, _) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .hostError)
        #expect(message == "not found")
    }
}
```

Verify `PageModelClient`'s test initializer's exact label (`toolCaller:`, confirmed at `PageModelClient.swift:26`) and `MCPClient.ToolCallResult`/`.Content`'s real initializer before trusting the fake above verbatim — construct it exactly as `Tests/AnglesiteCoreTests/PageModelClientTests.swift` already does (read that file first: `Read Tests/AnglesiteCoreTests/PageModelClientTests.swift`) and match its pattern rather than guessing the initializer shape.

- [ ] **Step 2: Run to verify failure**

```bash
swift test --package-path . --filter SidecarWYSIWYGHostTransportTests
```
Expected: build failure, `SidecarWYSIWYGHostTransport` doesn't exist.

- [ ] **Step 3: Implement the transport**

```swift
import Foundation

/// Real `WYSIWYGHostTransport` conformance, backed by the sidecar's `get_page_model` tool and
/// its `apply_edit` block-editor ops. Successor to `StubWYSIWYGHostTransport` for production use
/// (#1222) — see this feature's plan doc for the two-round-trip design (`sendOp` applies, then
/// re-fetches the model; the sidecar doesn't piggyback a fresh page model onto these ops' reply).
public actor SidecarWYSIWYGHostTransport: WYSIWYGHostTransport {
    private let path: String
    private let pageModelClient: PageModelClient
    private let editRouter: any EditRouter
    private var listeners: [UUID: @Sendable (BlockModel) -> Void] = [:]

    public init(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter) {
        self.path = path
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }

    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let message = WYSIWYGOpTranslator.translate(envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion)
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            do {
                let fresh = try await pageModelClient.fetch(path: path)
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

    public func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void {
        // No live external-edit push exists yet — mirrors StubWYSIWYGHostTransport's own
        // not-yet-wired listener registry (same TODO, same reasoning: keeps protocol parity for
        // when a real push mechanism lands, without inventing one here).
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeListener(token) }
        }
    }

    private func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --package-path . --filter SidecarWYSIWYGHostTransportTests
```
Expected: PASS, all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/SidecarWYSIWYGHostTransport.swift Tests/AnglesiteCoreTests/SidecarWYSIWYGHostTransportTests.swift
git commit -m "feat(#1222): add sidecar-backed WYSIWYGHostTransport"
```

---

### Task 5: Wire the real transport into `PreviewModel.enterEditMode`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift` (`enterEditMode`, lines 124-144)
- Modify: `Sources/AnglesiteApp/PreviewNavigationCommands.swift` (`editModeBinding`, lines 100-115)
- Test: `Tests/AnglesiteAppTests/WYSIWYGPlumbingIntegrationTests.swift` (extend — read it first to match its existing setup pattern before adding to it)

**Interfaces:**
- Consumes: `SidecarWYSIWYGHostTransport` (Task 4), `PageModelBlockAdapter.adapt` (Task 3), `PageSourcePath.resolve(route:pages:)` (`PageSourcePath.swift:34`, already used identically by `SiteWindowModel.effectPlacementController`, `SiteWindowModel.swift:1643`), `PageModelClient` (existing).

- [ ] **Step 1: Read the two call sites in full before editing**

```bash
sed -n '1,50p;80,150p' Sources/AnglesiteApp/PreviewModel.swift
sed -n '85,116p' Sources/AnglesiteApp/PreviewNavigationCommands.swift
grep -n "scannedPages\|effectPlacementController" Sources/AnglesiteApp/SiteWindowModel.swift
```
Confirm `PreviewModel` already exposes (or can cheaply expose) an `mcpClient()` accessor (`PreviewModel.swift:562`) and `editRouter` (`PreviewModel.swift:85`) — both are needed to build the new transport and a `PageModelClient` inline, mirroring `SiteWindowModel.makeEffectPlacementController(path:)`'s exact construction (`SiteWindowModel.swift:1656-1662`).

- [ ] **Step 2: Change `enterEditMode`'s signature to take a path, not a placeholder model**

In `Sources/AnglesiteApp/PreviewModel.swift`, replace:
```swift
    func enterEditMode(seedModel: BlockModel, undoManager: UndoManager?) async {
        let transport = StubWYSIWYGHostTransport(model: seedModel)
        let canvas = WYSIWYGCanvasController(initialModel: seedModel, transport: transport)
```
with:
```swift
    /// - Parameter path: project-relative `.astro` page path (e.g. `src/pages/index.astro`),
    ///   resolved by the caller via `PageSourcePath.resolve(route:pages:)` — mirrors
    ///   `SiteWindowModel.makeEffectPlacementController(path:)`'s existing resolution, not
    ///   duplicated here since this model has no access to the site's scanned-pages graph.
    func enterEditMode(path: String, undoManager: UndoManager?) async {
        let pageModelClient = PageModelClient(mcpClient: { [weak self] in await self?.runtime.mcpClient })
        let transport = SidecarWYSIWYGHostTransport(path: path, pageModelClient: pageModelClient, editRouter: editRouter)
        let seedModel: BlockModel
        do {
            seedModel = PageModelBlockAdapter.adapt(try await pageModelClient.fetch(path: path))
        } catch {
            await LogCenter.shared.append(source: "wysiwyg", stream: .stderr, text: "enterEditMode: get_page_model failed for \(path): \(error)")
            return // canvas stays nil — the Edit Page toggle simply doesn't turn on (see plan's design decision 4)
        }
        let canvas = WYSIWYGCanvasController(initialModel: seedModel, transport: transport)
```
Everything below the changed lines (undo manager wiring, `qualityGateContext`, `wysiwygCanvas = canvas`, `mountEngine()`, `runQualityGates`) stays as-is — re-read lines 127-147 after this edit to confirm nothing downstream still references the old `seedModel` parameter name in a way that breaks.

Check `LogCenter.shared.append(source:stream:text:)`'s exact signature against an existing call site (e.g. `EditRouter.swift:146-150`'s `LoggingEditRouter.apply`) before trusting the snippet above verbatim.

- [ ] **Step 3: Update the call site**

In `Sources/AnglesiteApp/PreviewNavigationCommands.swift`, replace:
```swift
                if isOn {
                    let seed = BlockModel(
                        path: focusedPreview.activeRoute ?? "/", version: "v0", rootIds: [], blocks: [:])
                    let undoManager = focusedSiteWindowModel?.windowUndoManager
                    Task { await focusedPreview.enterEditMode(seedModel: seed, undoManager: undoManager) }
                } else {
```
with:
```swift
                if isOn {
                    let path = PageSourcePath.resolve(route: focusedPreview.activeRoute, pages: focusedSiteWindowModel?.scannedPages ?? [])
                    let undoManager = focusedSiteWindowModel?.windowUndoManager
                    Task { await focusedPreview.enterEditMode(path: path, undoManager: undoManager) }
                } else {
```
Confirm `focusedSiteWindowModel?.scannedPages`'s exact type/accessibility (`grep -n "var scannedPages" Sources/AnglesiteApp/SiteWindowModel.swift`) — it's read the same way at `SiteWindowModel.swift:1643` inside the model itself; confirm it's also reachable from `PreviewNavigationCommands` (a separate `Commands`/`ToolbarContent`-adjacent type) or thread it through however `focusedSiteWindowModel` already exposes its properties to that file.

- [ ] **Step 4: Update existing tests that call the old signature**

```bash
grep -rln "enterEditMode(seedModel" Tests/
```
For each hit, change to the new `enterEditMode(path:undoManager:)` signature. Existing unit tests that only exercise `WYSIWYGCanvasController` directly (not `PreviewModel.enterEditMode`) — `WYSIWYGCanvasControllerTests`, `WYSIWYGBlockContextMenuTests` — are unaffected; they construct the controller directly against `StubWYSIWYGHostTransport`, which still exists and is still valid for that kind of isolated test.

- [ ] **Step 5: Add one integration test proving the real seam wires end-to-end**

Read `Tests/AnglesiteAppTests/WYSIWYGPlumbingIntegrationTests.swift` first to match its existing `PreviewModel` construction/fixture pattern exactly, then add:

```swift
@Test func enterEditModeFetchesRealModelThroughSidecarTransport() async {
    // Arrange a PreviewModel whose runtime.mcpClient/editRouter are faked to return a canned
    // get_page_model result and a canned apply_edit .applied reply — mirror whatever fixture
    // helper this file already uses to build a PreviewModel with an injectable MCPClient (check
    // for one before writing a new one from scratch).
    // ...
    await previewModel.enterEditMode(path: "src/pages/index.astro", undoManager: nil)
    #expect(previewModel.isEditModeEnabled)
}
```
This step's exact body depends on this test file's existing fixture machinery — read it fully before writing rather than guessing; the assertion (`isEditModeEnabled` true after a successful fetch) is the one thing this plan can commit to without seeing that fixture.

- [ ] **Step 6: Run the full test suite and app build**

```bash
swift test --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: all green, BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/PreviewNavigationCommands.swift Tests/AnglesiteAppTests/WYSIWYGPlumbingIntegrationTests.swift
git commit -m "feat(#1222): wire SidecarWYSIWYGHostTransport into PreviewModel.enterEditMode"
```

---

### Task 6: Re-vendor the container image and manual smoke test

**Files:** none (operational task)

- [ ] **Step 1: Re-vendor** (once Task 0's tag is pushed)

```bash
ANGLESITE_SIDECAR_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite-skills scripts/vendor-container-image.sh
```
Confirm the script picks up the new tag (check its output/logs for the version it vendored).

- [ ] **Step 2: Manual smoke test** (no GUI automation available in a headless session — this step is for whoever has an interactive Mac session)

Per `docs/testing-macos-app.md`: launch the app, open a real `.anglesite` site, toggle Site ▸ Edit Page, and confirm:
1. The canvas seeds with the page's actual content (not empty) — proves `get_page_model` round-tripped.
2. Insert a block from the palette, and confirm it appears in the live preview *and* survives a reload (proves the write landed in `Source/`, not just in-memory).
3. Undo the insert (⌘Z) and confirm it reverts.
4. Edit some inline text, confirm it round-trips.

- [ ] **Step 3: Record the smoke-test result in the PR body's Test plan section** — this plan's PR cannot claim "manual smoke: done" without this step actually having been run by a human with the app open.

---

## Self-review

**Spec coverage:** Task 0 covers the release-tag prerequisite. Tasks 1-2 cover the wire-format mismatch (design decision area). Task 3 covers the model-shape mismatch (design decisions 2-3). Task 4 covers the transport itself, including the two-round-trip design and stale/error mapping. Task 5 covers wiring it into the one production call site (`PreviewModel.enterEditMode`) and its one caller (`PreviewNavigationCommands`). Task 6 covers re-vendoring + a manual check. The two documented sidecar v1 gaps and server-computed `inverse` are explicitly out of scope per design decision 1, with a clear pointer to file follow-up work once this lands.

**Placeholder scan:** No bare "TODO"/"handle errors appropriately" steps. Two narrow, explicitly-reasoned simplifications are left in code comments rather than solved speculatively (`WYSIWYGOpTranslator.stringValue`'s object/array case, `nodeSpec`'s `.text` case) — each names exactly what's missing and why, not "TBD."

**Type consistency:** `BlockKind.element`/`.fragment` (Task 3) are referenced consistently in the adapter and nowhere else needs to change since `Op`/`OpResult`/`OpEnvelope` are kind-agnostic. `WYSIWYGOpTranslator.translate` and `SidecarWYSIWYGHostTransport.sendOp` use matching parameter names (`requestId`/`envelope.id`, `path`, `baseVersion`/`envelope.targetVersion`) — verified by re-reading both signatures side by side.
