# WYSIWYG Mac Host Chrome — PR1 (Plumbing) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get an op from a menu command or in-canvas gesture across a new Swift↔JS bridge, applied against a local stub backend, and undoable through `NSUndoManager` — the vertical slice that proves the whole host seam works before any native panel UI exists (issue #1225, PR1 of 3).

**Architecture:** A new dedicated `WKScriptMessageHandler` ("wysiwyg" namespace) carries `OpEnvelope`/`OpResult` JSON between a Swift `Op` vocabulary (mirroring `JS/wysiwyg-engine/src/types.ts`) and the existing JS engine, adapted via a new `NativeHostTransport`. Swift applies ops against an in-memory `StubWYSIWYGHostTransport` (no real git write — the real sidecar-backed transport is a follow-up once #1222 unblocks). The canvas mounts as an edit-mode toggle inside the existing `.preview` pane. `WYSIWYGCanvasController` (owned by `PreviewModel`) is the app-side orchestrator that menu commands and the undo coordinator talk to.

**Tech Stack:** Swift 6.4 (`AnglesiteCore`, `AnglesiteBridgeCore`, `AnglesiteBridge`, `AnglesiteApp` targets), Swift Testing, TypeScript (`JS/wysiwyg-engine/`), vitest, esbuild.

## Global Constraints

- Swift/SwiftUI + Apple frameworks only — no third-party dependencies (CONTRIBUTING.md).
- Process spawning stays centralized in `AnglesiteCore/ProcessSupervisor` — not touched by this plan.
- No silent failure paths — every bridge rejection/drop logs via `LogCenter` (CLAUDE.md "logs are sacred").
- Conventional commits, subject ≤72 chars, reference `#1225` (CONTRIBUTING.md).
- Follow existing patterns exactly where one already exists for the same shape (bridge dispatcher/handler split, `FocusedValueKey`, `PlannedItem`→live-`Button` convention) — this plan cites the file:line of each precedent it follows.
- `StubWYSIWYGHostTransport` applies ops to an in-memory model only. No real source write, no git commit — swapping in the real sidecar-backed transport is explicitly out of scope (waits on #1222).

---

### Task 1: Swift ops vocabulary types

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGOpsTests.swift`

**Interfaces:**
- Produces: `BlockId` (`= String`), `PropValue`, `RichTextRun`, `BlockKind`, `BlockNode`, `BlockNodeContent`, `rootParentID` (`String`), `ParentRef` (`= String`), `BlockModel`, `Op`, `OpEnvelope`, `OpRejectionReason`, `OpResult` — all `Codable, Equatable, Sendable`, wire-compatible with `JS/wysiwyg-engine/src/types.ts`.

This ports the JS discriminated-union `Op`/`OpResult` types to Swift with **flat JSON matching the JS wire shape** (a `"kind"`/`"status"` field alongside the variant's own fields, not Swift's default enum-with-associated-values encoding) — required because the JS engine on the other side of the bridge is the source of truth for the wire format.

- [ ] **Step 1: Write the failing round-trip test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYG ops Codable round-trip")
struct WYSIWYGOpsTests {
    @Test("insertBlock encodes with a flat kind discriminator matching the JS wire shape")
    func insertBlockWireShape() throws {
        let op = Op.insertBlock(
            parentId: rootParentID, slot: "main", index: 0, newId: "b1",
            block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        )
        let data = try JSONEncoder().encode(op)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "insertBlock")
        #expect(json?["parentId"] as? String == rootParentID)
        #expect(json?["newId"] as? String == "b1")
        #expect((json?["block"] as? [String: Any])?["id"] == nil, "insertBlock's block payload must omit id, matching TS's Omit<BlockNode, \"id\">")
    }

    @Test("Op round-trips through encode/decode for every kind")
    func allKindsRoundTrip() throws {
        let content = BlockNodeContent(kind: .astro, componentName: "Testimonial", props: ["quote": .string("hi")], slots: [:], sourceSpan: [10, 20], richText: nil)
        let node = BlockNode(id: "b2", kind: .astro, componentName: "Testimonial", props: [:], slots: [:], sourceSpan: [0, 5], richText: nil)
        let ops: [Op] = [
            .insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: content),
            .deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "b2", block: node),
            .moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 0, toParentId: rootParentID, toSlot: "main", toIndex: 1),
            .setProp(blockId: "b1", propName: "title", value: .string("new"), previousValue: .string("old")),
            .editText(blockId: "b1", runs: [RichTextRun(kind: .text, text: "hi")], previousRuns: []),
            .setDesignToken(tokenName: "color.primary", value: "#000", previousValue: "#fff"),
        ]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(Op.self, from: data)
            #expect(decoded == op)
        }
    }

    @Test("OpResult applied/rejected round-trip with a flat status discriminator")
    func opResultWireShape() throws {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
        let applied = OpResult.applied(model: model)
        let appliedData = try JSONEncoder().encode(applied)
        #expect(try JSONDecoder().decode(OpResult.self, from: appliedData) == applied)

        let rejected = OpResult.rejected(reason: .versionMismatch, message: "stale", freshModel: model)
        let rejectedJSON = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(rejected)) as? [String: Any]
        #expect(rejectedJSON?["status"] as? String == "rejected")
        #expect(rejectedJSON?["reason"] as? String == "version-mismatch")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGOpsTests`
Expected: FAIL — `WYSIWYGOpsTests`/`Op`/`BlockModel` etc. don't exist yet (build error).

- [ ] **Step 3: Write the types**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift
import Foundation

// The ops protocol (spec: docs/superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md §3.2).
// Wire-compatible with JS/wysiwyg-engine/src/types.ts — every Codable shape here mirrors that
// file's JSON exactly (flat "kind"/"status" discriminator, matching field names) because the JS
// engine on the other side of the bridge is the source of truth for the wire format.

public typealias BlockId = String

public indirect enum PropValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: PropValue])
    case array([PropValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: PropValue].self) { self = .object(v); return }
        if let v = try? container.decode([PropValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized PropValue")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }
}

public struct RichTextRun: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, strong, em, link, code
    }
    public var kind: Kind
    public var text: String
    public var href: String?
    public var children: [RichTextRun]?

    public init(kind: Kind, text: String, href: String? = nil, children: [RichTextRun]? = nil) {
        self.kind = kind
        self.text = text
        self.href = href
        self.children = children
    }
}

public enum BlockKind: String, Codable, Sendable {
    case astro
    case customElement = "custom-element"
    case text
}

/// Full block node, including its `id` — matches TS `BlockNode`.
public struct BlockNode: Codable, Equatable, Sendable {
    public var id: BlockId
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    /// `[start, end)` byte offsets into the source file — a 2-element array, matching TS's tuple.
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?

    public init(id: BlockId, kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil) {
        self.id = id
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
    }
}

/// `BlockNode` without `id` — matches TS's `Omit<BlockNode, "id">`, used by `insertBlock`'s payload
/// (the id travels separately as `newId`).
public struct BlockNodeContent: Codable, Equatable, Sendable {
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?

    public init(kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil) {
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
    }
}

/// Sentinel parent for blocks that live at the page root — matches TS `ROOT_PARENT_ID`.
public let rootParentID: BlockId = "__root__"
public typealias ParentRef = BlockId

public struct BlockModel: Codable, Equatable, Sendable {
    public var path: String
    public var version: String
    public var rootIds: [BlockId]
    public var blocks: [BlockId: BlockNode]

    public init(path: String, version: String, rootIds: [BlockId], blocks: [BlockId: BlockNode]) {
        self.path = path
        self.version = version
        self.rootIds = rootIds
        self.blocks = blocks
    }
}

/// Engine -> host semantic ops (spec §3.2). Every case here MUST have a matching case in
/// `WYSIWYGOpInverter.invert` — see that file's header comment.
public enum Op: Equatable, Sendable {
    case insertBlock(parentId: ParentRef, slot: String, index: Int, newId: BlockId, block: BlockNodeContent)
    case deleteBlock(parentId: ParentRef, slot: String, index: Int, blockId: BlockId, block: BlockNode)
    case moveBlock(blockId: BlockId, fromParentId: ParentRef, fromSlot: String, fromIndex: Int, toParentId: ParentRef, toSlot: String, toIndex: Int)
    case setProp(blockId: BlockId, propName: String, value: PropValue, previousValue: PropValue)
    case editText(blockId: BlockId, runs: [RichTextRun], previousRuns: [RichTextRun])
    case setDesignToken(tokenName: String, value: String, previousValue: String)
}

extension Op: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, parentId, slot, index, newId, block
        case blockId, fromParentId, fromSlot, fromIndex, toParentId, toSlot, toIndex
        case propName, value, previousValue
        case runs, previousRuns
        case tokenName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "insertBlock":
            self = .insertBlock(
                parentId: try container.decode(ParentRef.self, forKey: .parentId),
                slot: try container.decode(String.self, forKey: .slot),
                index: try container.decode(Int.self, forKey: .index),
                newId: try container.decode(BlockId.self, forKey: .newId),
                block: try container.decode(BlockNodeContent.self, forKey: .block))
        case "deleteBlock":
            self = .deleteBlock(
                parentId: try container.decode(ParentRef.self, forKey: .parentId),
                slot: try container.decode(String.self, forKey: .slot),
                index: try container.decode(Int.self, forKey: .index),
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                block: try container.decode(BlockNode.self, forKey: .block))
        case "moveBlock":
            self = .moveBlock(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                fromParentId: try container.decode(ParentRef.self, forKey: .fromParentId),
                fromSlot: try container.decode(String.self, forKey: .fromSlot),
                fromIndex: try container.decode(Int.self, forKey: .fromIndex),
                toParentId: try container.decode(ParentRef.self, forKey: .toParentId),
                toSlot: try container.decode(String.self, forKey: .toSlot),
                toIndex: try container.decode(Int.self, forKey: .toIndex))
        case "setProp":
            self = .setProp(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                propName: try container.decode(String.self, forKey: .propName),
                value: try container.decode(PropValue.self, forKey: .value),
                previousValue: try container.decode(PropValue.self, forKey: .previousValue))
        case "editText":
            self = .editText(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                runs: try container.decode([RichTextRun].self, forKey: .runs),
                previousRuns: try container.decode([RichTextRun].self, forKey: .previousRuns))
        case "setDesignToken":
            self = .setDesignToken(
                tokenName: try container.decode(String.self, forKey: .tokenName),
                value: try container.decode(String.self, forKey: .value),
                previousValue: try container.decode(String.self, forKey: .previousValue))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unrecognized op kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insertBlock(let parentId, let slot, let index, let newId, let block):
            try container.encode("insertBlock", forKey: .kind)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(slot, forKey: .slot)
            try container.encode(index, forKey: .index)
            try container.encode(newId, forKey: .newId)
            try container.encode(block, forKey: .block)
        case .deleteBlock(let parentId, let slot, let index, let blockId, let block):
            try container.encode("deleteBlock", forKey: .kind)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(slot, forKey: .slot)
            try container.encode(index, forKey: .index)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(block, forKey: .block)
        case .moveBlock(let blockId, let fromParentId, let fromSlot, let fromIndex, let toParentId, let toSlot, let toIndex):
            try container.encode("moveBlock", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(fromParentId, forKey: .fromParentId)
            try container.encode(fromSlot, forKey: .fromSlot)
            try container.encode(fromIndex, forKey: .fromIndex)
            try container.encode(toParentId, forKey: .toParentId)
            try container.encode(toSlot, forKey: .toSlot)
            try container.encode(toIndex, forKey: .toIndex)
        case .setProp(let blockId, let propName, let value, let previousValue):
            try container.encode("setProp", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(propName, forKey: .propName)
            try container.encode(value, forKey: .value)
            try container.encode(previousValue, forKey: .previousValue)
        case .editText(let blockId, let runs, let previousRuns):
            try container.encode("editText", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(runs, forKey: .runs)
            try container.encode(previousRuns, forKey: .previousRuns)
        case .setDesignToken(let tokenName, let value, let previousValue):
            try container.encode("setDesignToken", forKey: .kind)
            try container.encode(tokenName, forKey: .tokenName)
            try container.encode(value, forKey: .value)
            try container.encode(previousValue, forKey: .previousValue)
        }
    }
}

public struct OpEnvelope: Codable, Equatable, Sendable {
    public var id: String
    /// The model version (content hash) this op was computed against — spec §9.
    public var targetVersion: String
    public var op: Op

    public init(id: String, targetVersion: String, op: Op) {
        self.id = id
        self.targetVersion = targetVersion
        self.op = op
    }
}

public enum OpRejectionReason: String, Codable, Sendable {
    case versionMismatch = "version-mismatch"
    case invalidTarget = "invalid-target"
    case hostError = "host-error"
}

public enum OpResult: Equatable, Sendable {
    case applied(model: BlockModel)
    case rejected(reason: OpRejectionReason, message: String?, freshModel: BlockModel?)
}

extension OpResult: Codable {
    private enum CodingKeys: String, CodingKey { case status, model, reason, message, freshModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "applied":
            self = .applied(model: try container.decode(BlockModel.self, forKey: .model))
        case "rejected":
            self = .rejected(
                reason: try container.decode(OpRejectionReason.self, forKey: .reason),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                freshModel: try container.decodeIfPresent(BlockModel.self, forKey: .freshModel))
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unrecognized status: \(status)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applied(let model):
            try container.encode("applied", forKey: .status)
            try container.encode(model, forKey: .model)
        case .rejected(let reason, let message, let freshModel):
            try container.encode("rejected", forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encodeIfPresent(freshModel, forKey: .freshModel)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGOpsTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift Tests/AnglesiteCoreTests/WYSIWYGOpsTests.swift
git commit -m "feat(#1225): add Swift WYSIWYG ops vocabulary types"
```

---

### Task 2: `invertOp` port

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGOpInverterTests.swift`

**Interfaces:**
- Consumes: `Op`, `BlockNode`, `BlockNodeContent`, `rootParentID` (Task 1).
- Produces: `WYSIWYGOpInverter.invert(_ op: Op) -> Op`.

Direct port of `JS/wysiwyg-engine/src/ops.ts`'s `invertOp` (lines 13-67) — the single source of truth for "every op ships with its inverse" (spec §3.2), needed directly for `NSUndoManager` registration in Task 9.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYG op inversion")
struct WYSIWYGOpInverterTests {
    @Test("insertBlock inverts to deleteBlock at the same position")
    func insertInverts() {
        let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 2, newId: "b9", block: content)
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .deleteBlock(
            parentId: rootParentID, slot: "main", index: 2, blockId: "b9",
            block: BlockNode(id: "b9", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])))
    }

    @Test("inverting an op twice returns an op equivalent to the original")
    func doubleInversionRoundTrips() {
        let op = Op.setProp(blockId: "b1", propName: "title", value: .string("new"), previousValue: .string("old"))
        #expect(WYSIWYGOpInverter.invert(WYSIWYGOpInverter.invert(op)) == op)
    }

    @Test("moveBlock inversion swaps from/to")
    func moveInverts() {
        let op = Op.moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 0, toParentId: rootParentID, toSlot: "main", toIndex: 2)
        let inverse = WYSIWYGOpInverter.invert(op)
        #expect(inverse == .moveBlock(blockId: "b1", fromParentId: rootParentID, fromSlot: "main", fromIndex: 2, toParentId: rootParentID, toSlot: "main", toIndex: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WYSIWYGOpInverterTests`
Expected: FAIL — `WYSIWYGOpInverter` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift
import Foundation

/// Every op ships with its inverse (spec §3.2) — this is the single source of truth for that
/// guarantee on the Swift side, ported line-for-line from `JS/wysiwyg-engine/src/ops.ts`'s
/// `invertOp`. A missing/wrong case here is a protocol bug, not a style nit.
public enum WYSIWYGOpInverter {
    public static func invert(_ op: Op) -> Op {
        switch op {
        case .insertBlock(let parentId, let slot, let index, let newId, let block):
            return .deleteBlock(
                parentId: parentId, slot: slot, index: index, blockId: newId,
                block: BlockNode(id: newId, kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText))
        case .deleteBlock(let parentId, let slot, let index, let blockId, let block):
            return .insertBlock(
                parentId: parentId, slot: slot, index: index, newId: blockId,
                block: BlockNodeContent(kind: block.kind, componentName: block.componentName, props: block.props, slots: block.slots, sourceSpan: block.sourceSpan, richText: block.richText))
        case .moveBlock(let blockId, let fromParentId, let fromSlot, let fromIndex, let toParentId, let toSlot, let toIndex):
            return .moveBlock(blockId: blockId, fromParentId: toParentId, fromSlot: toSlot, fromIndex: toIndex, toParentId: fromParentId, toSlot: fromSlot, toIndex: fromIndex)
        case .setProp(let blockId, let propName, let value, let previousValue):
            return .setProp(blockId: blockId, propName: propName, value: previousValue, previousValue: value)
        case .editText(let blockId, let runs, let previousRuns):
            return .editText(blockId: blockId, runs: previousRuns, previousRuns: runs)
        case .setDesignToken(let tokenName, let value, let previousValue):
            return .setDesignToken(tokenName: tokenName, value: previousValue, previousValue: value)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WYSIWYGOpInverterTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGOpInverter.swift Tests/AnglesiteCoreTests/WYSIWYGOpInverterTests.swift
git commit -m "feat(#1225): port invertOp to Swift for NSUndoManager registration"
```

---

### Task 3: `StubWYSIWYGHostTransport`

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift` (protocol)
- Create: `Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift`
- Test: `Tests/AnglesiteCoreTests/StubWYSIWYGHostTransportTests.swift`

**Interfaces:**
- Consumes: `Op`, `OpEnvelope`, `OpResult`, `BlockModel`, `BlockNode`, `rootParentID` (Task 1).
- Produces: `protocol WYSIWYGHostTransport: Sendable { func sendOp(_:) async -> OpResult; func onModelUpdate(_:) -> () -> Void }`; `actor StubWYSIWYGHostTransport: WYSIWYGHostTransport`.

Applies ops to an in-memory `BlockModel`, mirroring `JS/wysiwyg-engine/src/testing/fixture-host.ts`'s `sendOp`/`applyOp`/`spliceIntoSlot` (lines 26-172) — the same precedent slices 2-3 used for the JS engine's own tests. No real source write or git commit (design doc §1).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AnglesiteCore

@Suite("StubWYSIWYGHostTransport")
struct StubWYSIWYGHostTransportTests {
    static func emptyModel() -> BlockModel {
        BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    }

    @Test("rejects an op targeting a stale version")
    func rejectsStaleVersion() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "wrong-version", op: op))
        guard case .rejected(let reason, _, let freshModel) = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(reason == .versionMismatch)
        #expect(freshModel?.version == "v0")
    }

    @Test("applies insertBlock at the page root and bumps the version")
    func appliesInsertAtRoot() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .applied(let model) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(model.rootIds == ["b1"])
        #expect(model.blocks["b1"]?.componentName == "p")
        #expect(model.version != "v0")
    }

    @Test("deleteBlock removes the block and its root entry")
    func appliesDelete() async {
        let inserted = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let seeded = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": inserted])
        let transport = StubWYSIWYGHostTransport(model: seeded)
        let op = Op.deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "b1", block: inserted)
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .applied(let model) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(model.rootIds.isEmpty)
        #expect(model.blocks["b1"] == nil)
    }

    @Test("deleteBlock targeting an unknown block is rejected as invalid-target")
    func rejectsInvalidTarget() async {
        let transport = StubWYSIWYGHostTransport(model: Self.emptyModel())
        let ghost = BlockNode(id: "ghost", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let op = Op.deleteBlock(parentId: rootParentID, slot: "main", index: 0, blockId: "ghost", block: ghost)
        let result = await transport.sendOp(OpEnvelope(id: "1", targetVersion: "v0", op: op))
        guard case .rejected(let reason, _, _) = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(reason == .invalidTarget)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StubWYSIWYGHostTransportTests`
Expected: FAIL — `StubWYSIWYGHostTransport` doesn't exist yet.

- [ ] **Step 3: Write the protocol and implementation**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift
import Foundation

/// Host -> engine seam (spec §3.2/§3.3), Swift-side counterpart to
/// `JS/wysiwyg-engine/src/types.ts`'s `HostTransport`. `StubWYSIWYGHostTransport` implements it
/// against an in-memory model for now; a real sidecar-backed implementation lands once #1222
/// unblocks.
public protocol WYSIWYGHostTransport: Sendable {
    func sendOp(_ envelope: OpEnvelope) async -> OpResult
    /// Host-initiated model push — a re-render notification, e.g. after an outside hand edit.
    /// Returns an unsubscribe closure.
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) -> () -> Void
}
```

```swift
// Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift
import Foundation

/// Applies ops to an in-memory `BlockModel` only — no real source write, no git commit. Mirrors
/// `JS/wysiwyg-engine/src/testing/fixture-host.ts`'s reducer so both sides of the protocol are
/// exercised against equivalent stand-ins until the real sidecar-backed transport lands (#1222).
public actor StubWYSIWYGHostTransport: WYSIWYGHostTransport {
    private var model: BlockModel
    private var listeners: [UUID: @Sendable (BlockModel) -> Void] = [:]

    public init(model: BlockModel) {
        self.model = model
    }

    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        guard envelope.targetVersion == model.version else {
            return .rejected(reason: .versionMismatch, message: "stale model version", freshModel: model)
        }
        guard let next = Self.applying(envelope.op, to: model) else {
            return .rejected(reason: .invalidTarget, message: "target block not found", freshModel: nil)
        }
        model = next
        return .applied(model: next)
    }

    public func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) -> () -> Void {
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

    /// Pure reducer, ported from `fixture-host.ts`'s `applyOp`/`spliceIntoSlot`. Returns `nil` on
    /// an invalid target (parent/index/block not found) rather than throwing.
    static func applying(_ op: Op, to model: BlockModel) -> BlockModel? {
        var blocks = model.blocks
        var rootIds = model.rootIds

        func spliceOut(parentId: ParentRef, slot: String, blockId: BlockId) -> Bool {
            if parentId == rootParentID {
                guard let idx = rootIds.firstIndex(of: blockId) else { return false }
                rootIds.remove(at: idx)
                return true
            }
            guard var parent = blocks[parentId], var ids = parent.slots[slot], let idx = ids.firstIndex(of: blockId) else { return false }
            ids.remove(at: idx)
            parent.slots[slot] = ids
            blocks[parentId] = parent
            return true
        }

        func spliceIn(parentId: ParentRef, slot: String, index: Int, blockId: BlockId) -> Bool {
            if parentId == rootParentID {
                guard index >= 0, index <= rootIds.count else { return false }
                rootIds.insert(blockId, at: index)
                return true
            }
            guard var parent = blocks[parentId] else { return false }
            var ids = parent.slots[slot] ?? []
            guard index >= 0, index <= ids.count else { return false }
            ids.insert(blockId, at: index)
            parent.slots[slot] = ids
            blocks[parentId] = parent
            return true
        }

        switch op {
        case .insertBlock(let parentId, let slot, let index, let newId, let content):
            blocks[newId] = BlockNode(id: newId, kind: content.kind, componentName: content.componentName, props: content.props, slots: content.slots, sourceSpan: content.sourceSpan, richText: content.richText)
            guard spliceIn(parentId: parentId, slot: slot, index: index, blockId: newId) else { return nil }

        case .deleteBlock(let parentId, let slot, _, let blockId, _):
            guard spliceOut(parentId: parentId, slot: slot, blockId: blockId) else { return nil }
            blocks.removeValue(forKey: blockId)

        case .moveBlock(let blockId, let fromParentId, let fromSlot, _, let toParentId, let toSlot, let toIndex):
            guard spliceOut(parentId: fromParentId, slot: fromSlot, blockId: blockId) else { return nil }
            guard spliceIn(parentId: toParentId, slot: toSlot, index: toIndex, blockId: blockId) else { return nil }

        case .setProp(let blockId, let propName, let value, _):
            guard var node = blocks[blockId] else { return nil }
            node.props[propName] = value
            blocks[blockId] = node

        case .editText(let blockId, let runs, _):
            guard var node = blocks[blockId] else { return nil }
            node.richText = runs
            blocks[blockId] = node

        case .setDesignToken:
            break // Accepted but not modeled in the stub — matches fixture-host.ts's no-op case.
        }

        // A UUID-derived version is sufficient for a stub whose only job is "always differ after
        // a mutation" — fixture-host.ts's own hash is documented as never a real algorithm either.
        return BlockModel(path: model.path, version: "stub-\(UUID().uuidString)", rootIds: rootIds, blocks: blocks)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StubWYSIWYGHostTransportTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift Sources/AnglesiteCore/WYSIWYG/StubWYSIWYGHostTransport.swift Tests/AnglesiteCoreTests/StubWYSIWYGHostTransportTests.swift
git commit -m "feat(#1225): add StubWYSIWYGHostTransport in-memory ops backend"
```

---

### Task 4: Ops bridge — dispatcher + `WKScriptMessageHandler`

**Files:**
- Create: `Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift`
- Create: `Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift`

**Interfaces:**
- Consumes: `Op`, `OpEnvelope`, `OpResult`, `WYSIWYGHostTransport` (Tasks 1, 3).
- Produces: `WYSIWYGOpsDispatcher.dispatch(body:via:) async -> DispatchResult`; `WYSIWYGOpsDispatcher.scriptMessageNamespace` (`"wysiwyg"`); `WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler`.

A new, dedicated bridge — deliberately not an extension of `AnglesiteMessageDispatcher`/`AnglesiteScriptHandler` (`Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift:23-138`, `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift:23-198`), which speak the older edit-overlay protocol the block editor is meant to eventually replace. Mirrors that pair's dispatcher/handler split exactly: the portable dispatcher does the decode+route, the WKWebView-specific handler unwraps `WKScriptMessage` and evaluates the reply.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteBridgeCore
@testable import AnglesiteCore

@Suite("WYSIWYGOpsDispatcher")
struct WYSIWYGOpsDispatcherTests {
    actor RecordingTransport: WYSIWYGHostTransport {
        private(set) var received: [OpEnvelope] = []
        private let reply: OpResult
        init(reply: OpResult) { self.reply = reply }
        func sendOp(_ envelope: OpEnvelope) async -> OpResult {
            received.append(envelope)
            return reply
        }
        func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) -> () -> Void { {} }
    }

    static func validSubmitOpBody() -> [String: Any] {
        [
            "type": "submit-op",
            "envelope": [
                "id": "req-1",
                "targetVersion": "v0",
                "op": ["kind": "setDesignToken", "tokenName": "color.primary", "value": "#000", "previousValue": "#fff"],
            ],
        ]
    }

    @Test("dispatch routes submit-op to the transport and returns the result")
    func routesSubmitOp() async {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
        let transport = RecordingTransport(reply: .applied(model: model))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: Self.validSubmitOpBody(), via: transport)
        guard case .opResult(let requestId, let opResult) = result else {
            Issue.record("expected .opResult, got \(result)")
            return
        }
        #expect(requestId == "req-1")
        #expect(opResult == .applied(model: model))
        let received = await transport.received
        #expect(received.first?.id == "req-1")
    }

    @Test("dispatch rejects an unrecognized type")
    func rejectsUnknownType() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "nope"], via: transport)
        guard case .rejected(.unknownType(let type)) = result else {
            Issue.record("expected .rejected(.unknownType), got \(result)")
            return
        }
        #expect(type == "nope")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: FAIL — `WYSIWYGOpsDispatcher` doesn't exist yet.

- [ ] **Step 3: Write the dispatcher and handler**

```swift
// Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift
import Foundation
import AnglesiteCore

/// Webview-agnostic message schema + routing for the `wysiwyg` script-message namespace —
/// deliberately separate from `AnglesiteMessageDispatcher` (the older edit-overlay protocol).
/// One message type today: `submit-op`, an `OpEnvelope` the engine sends when the owner performs
/// a gesture; the reply is the resulting `OpResult`.
public enum WYSIWYGOpsDispatcher {
    public static let scriptMessageNamespace = "wysiwyg"

    public enum DispatchResult: Sendable {
        /// `submit-op` was applied against the transport; the adapter should reply with `result`
        /// keyed by `requestId` (the envelope's `id`).
        case opResult(requestId: String, result: OpResult)
        case rejected(RejectionReason)

        public enum RejectionReason: Sendable, Equatable {
            case notAnObject
            case missingType
            case wrongType
            case unknownType(String)
            case envelopeDecode(String)
        }
    }

    public static func dispatch(body: Any, via transport: any WYSIWYGHostTransport) async -> DispatchResult {
        guard let dict = body as? [String: Any] else { return .rejected(.notAnObject) }
        guard let rawType = dict["type"] else { return .rejected(.missingType) }
        guard let typeStr = rawType as? String else { return .rejected(.wrongType) }

        switch typeStr {
        case "submit-op":
            guard let payload = dict["envelope"],
                  JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let envelope = try? JSONDecoder().decode(OpEnvelope.self, from: data)
            else {
                return .rejected(.envelopeDecode("could not decode OpEnvelope from \"envelope\" field"))
            }
            let result = await transport.sendOp(envelope)
            return .opResult(requestId: envelope.id, result: result)
        default:
            return .rejected(.unknownType(typeStr))
        }
    }
}
```

```swift
// Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift
import Foundation
import WebKit
import AnglesiteCore
import AnglesiteBridgeCore

/// `WKScriptMessageHandler` adapter for the `wysiwyg` namespace — the WKWebView-specific thin
/// layer over `WYSIWYGOpsDispatcher`, mirroring `AnglesiteScriptHandler`'s split.
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    private let transport: any WYSIWYGHostTransport
    private let logCenter: LogCenter

    public init(transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared) {
        self.transport = transport
        self.logCenter = logCenter
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WYSIWYGOpsDispatcher.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let transport = self.transport
        let logCenter = self.logCenter
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport) {
            case .opResult(let requestId, let result):
                guard let webView else { return }
                guard let data = try? JSONEncoder().encode(result),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode OpResult for id=\(requestId)")
                    return
                }
                guard let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else { return }
                let script = "window.__anglesiteWysiwygHost?._handleOpResult?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift
git commit -m "feat(#1225): add dedicated WYSIWYG ops WKScriptMessageHandler bridge"
```

---

### Task 5: JS host adapter — `NativeHostTransport` + mount entry point

**Files:**
- Create: `JS/wysiwyg-engine/src/host/native-host-transport.ts`
- Create: `JS/wysiwyg-engine/src/host/mount.ts`
- Test: `JS/wysiwyg-engine/test/host/native-host-transport.test.ts`

**Interfaces:**
- Consumes: `HostTransport`, `OpEnvelope`, `OpResult`, `BlockModel` (`../types.js`); `WysiwygEngine` (`../engine.js`, constructor `(initialModel: BlockModel, transport: HostTransport)` per `JS/wysiwyg-engine/src/engine.ts:37`).
- Produces: `class NativeHostTransport implements HostTransport`; `window.__anglesiteWysiwygMount.mount(initialModel: BlockModel): WysiwygEngine`.

Implements the engine's `HostTransport` interface (`types.ts:118-122`) by posting to `window.webkit.messageHandlers.wysiwyg` (Task 4's bridge) and resolving pending promises when the native side calls back into `window.__anglesiteWysiwygHost._handleOpResult` — this is the "real host adapts this to the sidecar's MCP transport... FixtureHost adapts it to an in-memory model for tests" seam the `HostTransport` doc comment describes, now with a third adapter for the live native bridge. `WysiwygEngine` needs an `initialModel` at construction time (not fetchable through `HostTransport` itself), so mounting is a two-step handshake: Swift evaluates JS to call `mount(initialModel)` once it has a model from `StubWYSIWYGHostTransport`, rather than the bundle self-constructing at script-injection time.

- [ ] **Step 1: Write the failing test**

```typescript
// JS/wysiwyg-engine/test/host/native-host-transport.test.ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { NativeHostTransport } from "../../src/host/native-host-transport.js";

describe("NativeHostTransport", () => {
  let postedMessages: unknown[];

  beforeEach(() => {
    postedMessages = [];
    (window as any).webkit = {
      messageHandlers: {
        wysiwyg: { postMessage: (body: unknown) => postedMessages.push(body) },
      },
    };
    delete (window as any).__anglesiteWysiwygHost;
  });

  it("posts a submit-op message and resolves when the native side replies", async () => {
    const transport = new NativeHostTransport();
    void transport; // constructing installs window.__anglesiteWysiwygHost
    const envelope = { id: "req-1", targetVersion: "v0", op: { kind: "setDesignToken", tokenName: "t", value: "a", previousValue: "b" } } as const;
    const pending = transport.sendOp(envelope);
    expect(postedMessages).toEqual([{ type: "submit-op", envelope }]);
    const model = { path: "p", version: "v1", rootIds: [], blocks: {} };
    (window as any).__anglesiteWysiwygHost._handleOpResult("req-1", { status: "applied", model });
    await expect(pending).resolves.toEqual({ status: "applied", model });
  });

  it("notifies model-update listeners when the native side pushes one", () => {
    const transport = new NativeHostTransport();
    const seen: unknown[] = [];
    const unsubscribe = transport.onModelUpdate((model) => seen.push(model));
    const model = { path: "p", version: "v2", rootIds: [], blocks: {} };
    (window as any).__anglesiteWysiwygHost._handleModelUpdate(model);
    expect(seen).toEqual([model]);
    unsubscribe();
    (window as any).__anglesiteWysiwygHost._handleModelUpdate(model);
    expect(seen).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- native-host-transport`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Write the implementation**

```typescript
// JS/wysiwyg-engine/src/host/native-host-transport.ts
import type { HostTransport, OpEnvelope, OpResult, BlockModel } from "../types.js";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { wysiwyg?: { postMessage(body: unknown): void } } };
    __anglesiteWysiwygHost?: {
      _handleOpResult?: (requestId: string, result: OpResult) => void;
      _handleModelUpdate?: (model: BlockModel) => void;
    };
  }
}

/**
 * Adapts the engine's `HostTransport` interface to the native WKWebView bridge
 * (`Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`). Posts `submit-op` messages via
 * `window.webkit.messageHandlers.wysiwyg` and resolves pending promises when the native side
 * calls back into `window.__anglesiteWysiwygHost`.
 */
export class NativeHostTransport implements HostTransport {
  #pending = new Map<string, (result: OpResult) => void>();
  #modelListeners = new Set<(model: BlockModel) => void>();

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
}
```

```typescript
// JS/wysiwyg-engine/src/host/mount.ts
import { WysiwygEngine } from "../engine.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel) => WysiwygEngine };
  }
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    const engine = new WysiwygEngine(initialModel, new NativeHostTransport());
    window.__anglesiteWysiwygEngine = engine;
    return engine;
  },
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- native-host-transport`
Expected: PASS (2 tests)

- [ ] **Step 5: Typecheck and commit**

Run: `cd JS/wysiwyg-engine && npm run typecheck && npm run lint`
Expected: no errors.

```bash
git add JS/wysiwyg-engine/src/host/native-host-transport.ts JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/native-host-transport.test.ts
git commit -m "feat(#1225): add NativeHostTransport JS adapter for the ops bridge"
```

---

### Task 6: Build pipeline — bundle the WYSIWYG engine into a `WKUserScript`

**Files:**
- Create: `scripts/build-wysiwyg-engine.sh`
- Modify: `JS/wysiwyg-engine/package.json` (add a `build` script)
- Create: `Sources/AnglesiteBridgeCore/AnglesiteWysiwygEngineBundle.swift`
- Modify: `Sources/AnglesiteBridge/WebViewBridge.swift:31-44` (`localDevConfiguration`)
- Test: `Tests/AnglesiteBridgeCoreTests/AnglesiteWysiwygEngineBundleTests.swift`

**Interfaces:**
- Produces: `Resources/wysiwyg-engine/engine.js` (build artifact); `AnglesiteWysiwygEngineBundle.source(in:) -> String?`; `WebViewBridge.localDevConfiguration(handler:wysiwygHandler:bundle:)` (new `wysiwygHandler` parameter, default `nil`, backward compatible).

Mirrors `scripts/build-overlay.sh` + `AnglesiteOverlayBundle.swift` exactly for the new engine bundle — confirmed by direct read that `JS/wysiwyg-engine/` isn't referenced by any existing build script (it only builds vitest/Playwright fixtures today).

- [ ] **Step 1: Add a `build` script to `JS/wysiwyg-engine/package.json`**

Add alongside the existing `build:e2e` entry (same `esbuild ... --bundle --format=iife` convention):

```json
"build": "esbuild src/host/mount.ts --bundle --format=iife --target=es2022 --outfile=../../Resources/wysiwyg-engine/engine.js",
```

- [ ] **Step 2: Write the failing bundle-lookup test**

```swift
// Tests/AnglesiteBridgeCoreTests/AnglesiteWysiwygEngineBundleTests.swift
import Testing
import Foundation
@testable import AnglesiteBridgeCore

@Suite("AnglesiteWysiwygEngineBundle")
struct AnglesiteWysiwygEngineBundleTests {
    @Test("returns nil when the bundle resource is absent")
    func missingBundleReturnsNil() {
        // The test bundle (no "engine.js" resource under wysiwyg-engine/) stands in for a build
        // where the prebuild script was skipped — mirrors AnglesiteOverlayBundleTests' own case.
        #expect(AnglesiteWysiwygEngineBundle.source(in: Bundle.module) == nil)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter AnglesiteWysiwygEngineBundleTests`
Expected: FAIL — `AnglesiteWysiwygEngineBundle` doesn't exist yet.

- [ ] **Step 4: Write the build script, bundle lookup, and `WebViewBridge` wiring**

```bash
#!/usr/bin/env bash
# scripts/build-wysiwyg-engine.sh
#
# Builds JS/wysiwyg-engine/'s host mount entry point into
# Resources/wysiwyg-engine/engine.js, mirroring scripts/build-overlay.sh exactly. Best-effort:
# if Node isn't available or the install fails, warn and exit 0 so the Xcode build keeps going —
# WYSIWYGCanvasController logs the absence at runtime and edit mode just stays unavailable.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENGINE_DIR="$REPO_ROOT/JS/wysiwyg-engine"
DEST_DIR="$REPO_ROOT/Resources/wysiwyg-engine"

mkdir -p "$DEST_DIR"

if [[ ! -d "$ENGINE_DIR" ]]; then
    echo "warning: $ENGINE_DIR missing — skipping wysiwyg-engine build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping wysiwyg-engine build." >&2
    exit 0
fi

cd "$ENGINE_DIR"

if [[ ! -x "$ENGINE_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/wysiwyg-engine dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping wysiwyg-engine build." >&2
        exit 0
    fi
fi

echo "==> Type-checking JS/wysiwyg-engine"
"$NPM" run typecheck

echo "==> Building wysiwyg-engine → ${DEST_DIR#"$REPO_ROOT"/}/engine.js"
"$NPM" run build

bytes=$(wc -c < "$DEST_DIR/engine.js" | tr -d '[:space:]')
echo "WYSIWYG engine bundle: $DEST_DIR/engine.js (${bytes} bytes)"
```

```bash
chmod +x scripts/build-wysiwyg-engine.sh
```

```swift
// Sources/AnglesiteBridgeCore/AnglesiteWysiwygEngineBundle.swift
import Foundation

/// Locates the compiled WYSIWYG engine JS (built by `scripts/build-wysiwyg-engine.sh`) inside an
/// app bundle — mirrors `AnglesiteOverlayBundle` exactly for the new engine bundle.
public enum AnglesiteWysiwygEngineBundle {
    public static func source(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "engine", withExtension: "js", subdirectory: "wysiwyg-engine")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
```

Extend `WebViewBridge.localDevConfiguration` (`Sources/AnglesiteBridge/WebViewBridge.swift:31-44`) with a second optional handler, registered under `WYSIWYGOpsDispatcher.scriptMessageNamespace`, and inject the engine bundle as a second `WKUserScript` when present:

```swift
@MainActor
public static func localDevConfiguration(
    handler: WKScriptMessageHandler? = nil,
    wysiwygHandler: WKScriptMessageHandler? = nil,
    bundle: Bundle = .main
) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    #if DEBUG
    config.websiteDataStore = .nonPersistent()
    #endif
    enableWritingTools(on: config)
    if let handler {
        config.userContentController.add(handler, name: scriptMessageNamespace)
    }
    if let wysiwygHandler {
        config.userContentController.add(wysiwygHandler, name: WYSIWYGOpsDispatcher.scriptMessageNamespace)
    }
    if let script = makeOverlayUserScript(in: bundle) {
        config.userContentController.addUserScript(script)
    }
    if let engineSource = AnglesiteWysiwygEngineBundle.source(in: bundle) {
        config.userContentController.addUserScript(WKUserScript(source: engineSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }
    return config
}
```

(Add `import AnglesiteBridgeCore` if not already present at the top of `WebViewBridge.swift` — it already imports it per the file header.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AnglesiteWysiwygEngineBundleTests`
Expected: PASS

- [ ] **Step 6: Verify the build script runs end-to-end**

Run: `scripts/build-wysiwyg-engine.sh`
Expected: `Resources/wysiwyg-engine/engine.js` is created; script exits 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-wysiwyg-engine.sh JS/wysiwyg-engine/package.json Sources/AnglesiteBridgeCore/AnglesiteWysiwygEngineBundle.swift Sources/AnglesiteBridge/WebViewBridge.swift Tests/AnglesiteBridgeCoreTests/AnglesiteWysiwygEngineBundleTests.swift
git commit -m "feat(#1225): bundle the WYSIWYG engine as an injected WKUserScript"
```

*(Wiring `scripts/build-wysiwyg-engine.sh` into the Xcode build phase that already runs `scripts/build-overlay.sh` is a `project.yml` change — do it as part of this task if you have write access to `project.yml`'s prebuild script list; otherwise flag it explicitly in the PR description as a follow-up, since without it `Resources/wysiwyg-engine/` only gets populated by running the script manually.)*

---

### Task 7: `WYSIWYGCanvasController`

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Consumes: `Op`, `OpEnvelope`, `OpResult`, `BlockModel`, `WYSIWYGHostTransport`, `WYSIWYGOpInverter` (Tasks 1-3).
- Produces: `@MainActor @Observable final class WYSIWYGCanvasController`; `func submit(_ op: Op) async -> OpResult`; `var model: BlockModel`; `var selectedBlockId: BlockId?`; `var onOpApplied: ((Op, Op, BlockModel) -> Void)?` (consumed by Task 9's undo coordinator).

The app-side orchestrator menu commands and the undo coordinator talk to — owns the transport and current selection, and is the thing `PreviewModel` mounts (Task 8).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("WYSIWYGCanvasController")
@MainActor
struct WYSIWYGCanvasControllerTests {
    @Test("submit applies an op, updates model, and reports the applied op + inverse")
    func submitAppliesAndReportsInverse() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        var reported: (op: Op, inverse: Op, model: BlockModel)?
        controller.onOpApplied = { op, inverse, model in reported = (op, inverse, model) }

        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let result = await controller.submit(op)

        #expect(result.isApplied)
        #expect(controller.model.rootIds == ["b1"])
        #expect(reported?.op == op)
        #expect(reported?.inverse == WYSIWYGOpInverter.invert(op))
    }

    @Test("submit adopts the fresh model on a version-mismatch rejection without calling onOpApplied")
    func submitAdoptsFreshModelOnRejection() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.forceTargetVersion = "stale" // test-only seam, see Step 3
        var applied = false
        controller.onOpApplied = { _, _, _ in applied = true }

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let result = await controller.submit(op)

        guard case .rejected = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(applied == false)
    }
}

private extension OpResult {
    var isApplied: Bool { if case .applied = self { true } else { false } }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `WYSIWYGCanvasController` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift
import Foundation
import Observation
import AnglesiteCore

/// App-side orchestrator for one mounted WYSIWYG canvas (#1225). Owns the transport and current
/// block selection; menu commands (`FormatCommands`, Edit-menu Duplicate/Delete) and
/// `WYSIWYGUndoCoordinator` talk to this, not to the transport directly.
@MainActor @Observable
final class WYSIWYGCanvasController {
    private(set) var model: BlockModel
    var selectedBlockId: BlockId?
    private let transport: any WYSIWYGHostTransport

    /// Fires after every successfully applied op, with its inverse — `WYSIWYGUndoCoordinator`
    /// (Task 9) registers one `NSUndoManager` action per firing.
    var onOpApplied: ((Op, Op, BlockModel) -> Void)?

    /// Test-only seam: overrides the `targetVersion` a submitted envelope carries, so a test can
    /// force a version-mismatch rejection without needing two controllers racing a real one.
    var forceTargetVersion: String?

    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
    }

    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
        let result = await transport.sendOp(envelope)
        switch result {
        case .applied(let newModel):
            model = newModel
            onOpApplied?(op, WYSIWYGOpInverter.invert(op), newModel)
        case .rejected(_, _, let freshModel):
            if let freshModel { model = freshModel }
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1225): add WYSIWYGCanvasController orchestrator"
```

---

### Task 8: Mount the canvas — edit-mode toggle in `PreviewModel`/`PreviewView`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift` (add `wysiwygCanvas` + `isEditModeEnabled`/`enterEditMode()`)
- Modify: `Sources/AnglesiteApp/PreviewView.swift:40-66` (`makeNSView`)
- Test: `Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGCanvasController`, `WYSIWYGScriptHandler`, `StubWYSIWYGHostTransport`, `BlockModel` (Tasks 3, 4, 7).
- Produces: `PreviewModel.wysiwygCanvas: WYSIWYGCanvasController?`; `PreviewModel.isEditModeEnabled: Bool`; `PreviewModel.enterEditMode() async`; `PreviewModel.exitEditMode()`.

Reuses the existing `.preview` `WKWebView` rather than adding a new `MainPaneMode` case — the "Edit" toggle just constructs a `WYSIWYGCanvasController` against a seed `BlockModel` and registers the ops handler on the existing web view's configuration.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift
import Testing
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("PreviewModel WYSIWYG edit mode")
@MainActor
struct PreviewModelWYSIWYGTests {
    @Test("enterEditMode constructs a canvas controller; exitEditMode tears it down")
    func editModeLifecycle() async {
        let model = PreviewModel(runtime: FakeSiteRuntime())
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)

        await model.enterEditMode(seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]))
        #expect(model.isEditModeEnabled == true)
        #expect(model.wysiwygCanvas != nil)

        model.exitEditMode()
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)
    }
}
```

*(`FakeSiteRuntime` is the existing test double `PreviewModel`'s test suite already uses to construct a `PreviewModel` without a live runtime — reuse whatever the existing `PreviewModelTests` file constructs with; if that fixture has a different name, use the real one instead of inventing this identifier.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PreviewModelWYSIWYGTests`
Expected: FAIL — `enterEditMode`/`exitEditMode`/`wysiwygCanvas` don't exist yet.

- [ ] **Step 3: Add the edit-mode state to `PreviewModel`**

Add near the `editRouter` property (`PreviewModel.swift:81-85`):

```swift
/// The mounted WYSIWYG canvas controller, non-nil only while edit mode is active. Constructed
/// against a `StubWYSIWYGHostTransport` seeded with `seedModel` — the real sidecar-backed
/// transport is a follow-up once #1222 lands (design doc §1).
private(set) var wysiwygCanvas: WYSIWYGCanvasController?

var isEditModeEnabled: Bool { wysiwygCanvas != nil }

/// Site ▸ Edit Page toggle. `seedModel` stands in for a real `get_page_model` fetch (#1222)
/// until the sidecar backend exists.
func enterEditMode(seedModel: BlockModel) async {
    let transport = StubWYSIWYGHostTransport(model: seedModel)
    wysiwygCanvas = WYSIWYGCanvasController(initialModel: seedModel, transport: transport)
}

func exitEditMode() {
    wysiwygCanvas = nil
}
```

- [ ] **Step 4: Wire the ops handler into `PreviewView`**

`WYSIWYGCanvasController`'s own transport is private, so `WYSIWYGScriptHandler` needs something else to hold — make the controller itself conform to `WYSIWYGHostTransport` by forwarding to its private transport, so `PreviewView` can pass `model.preview.wysiwygCanvas` directly. Add to `WYSIWYGCanvasController` (Task 7's file):

```swift
extension WYSIWYGCanvasController: WYSIWYGHostTransport {
    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        await submit(envelope.op)
    }
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) -> () -> Void {
        {} // PR1 doesn't yet need host-initiated pushes into the controller itself; no-op for now.
    }
}
```

Add a `wysiwygTransport: (any WYSIWYGHostTransport)?` parameter to `PreviewView`'s init (default `nil`), and modify `PreviewView.makeNSView` (`Sources/AnglesiteApp/PreviewView.swift:40-66`) to pass a second handler through to `WebViewBridge.localDevConfiguration`:

```swift
let anglesiteHandler = AnglesiteScriptHandler(router: router, onVisibleElements: onVisibleElements)
let wysiwygHandler = wysiwygTransport.map { WYSIWYGScriptHandler(transport: $0) }
let configuration = WebViewBridge.localDevConfiguration(handler: anglesiteHandler, wysiwygHandler: wysiwygHandler)
```

Thread it from `SiteWindow.previewPane(for:)` (`Sources/AnglesiteApp/SiteWindow.swift:1052-1062`) as `wysiwygTransport: model.preview.wysiwygCanvas`.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PreviewModelWYSIWYGTests`
Expected: PASS

- [ ] **Step 6: Verify the app still builds**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/PreviewView.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/PreviewModelWYSIWYGTests.swift
git commit -m "feat(#1225): mount the WYSIWYG canvas as a .preview edit-mode toggle"
```

---

### Task 9: `WYSIWYGUndoCoordinator` — real `NSUndoManager` redo

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:127-149` (`windowUndoManager` didSet fan-out)
- Test: `Tests/AnglesiteCoreTests/WYSIWYGUndoCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Op`, `WYSIWYGOpInverter` (Tasks 1-2); `WYSIWYGCanvasController.onOpApplied` (Task 7).
- Produces: `@MainActor final class WYSIWYGUndoCoordinator`; `func registerApplied(op: Op, inverse: Op)`; `var undoManager: UndoManager?`.

Distinct from `EditUndoCoordinator` (`Sources/AnglesiteCore/EditUndoCoordinator.swift:1-166`, git-revert LIFO, **no redo**) — ops ship with their own inverse, so this coordinator registers each undo action as *itself* re-registering the forward op as the next undo action, giving real redo through `UndoManager`'s native mechanism (an undo handler that calls `registerUndo` again with the inverse operation, exactly how `UndoManager` expects a redo-capable client to behave).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGUndoCoordinator")
@MainActor
struct WYSIWYGUndoCoordinatorTests {
    @Test("registering an applied op sets a truthful action name and undoing calls perform with the inverse")
    func undoCallsPerformWithInverse() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in performed.append(op) }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        let inverse = WYSIWYGOpInverter.invert(op)
        coordinator.registerApplied(op: op, inverse: inverse)

        #expect(undoManager.undoActionName == "Undo Edit")
        undoManager.undo()
        #expect(performed == [inverse])
    }

    @Test("undoing then redoing performs the inverse then the original op")
    func redoPerformsOriginal() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var performed: [Op] = []
        let coordinator = WYSIWYGUndoCoordinator { op in performed.append(op) }
        coordinator.undoManager = undoManager

        let op = Op.setDesignToken(tokenName: "t", value: "a", previousValue: "b")
        coordinator.registerApplied(op: op, inverse: WYSIWYGOpInverter.invert(op))

        undoManager.undo()
        undoManager.redo()

        #expect(performed == [WYSIWYGOpInverter.invert(op), op])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WYSIWYGUndoCoordinatorTests`
Expected: FAIL — `WYSIWYGUndoCoordinator` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift
#if canImport(Darwin)
import Foundation

/// Bridges applied WYSIWYG ops into a window's `UndoManager` with **real redo** — unlike
/// `EditUndoCoordinator` (git-revert LIFO, no redo), every op ships its own inverse (spec §3.2),
/// so undoing an action re-registers the forward op as the next redo/undo step: standard
/// `UndoManager` usage for a redo-capable client.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Applies one op against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.submit(_:)` wrapped to discard its `OpResult`.
    public typealias Performer = @MainActor (Op) -> Void

    /// The focused window's undo manager. Weak: the window owns it.
    public weak var undoManager: UndoManager?

    private let perform: Performer

    public init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// Registers one applied op on the undo stack. Call from
    /// `WYSIWYGCanvasController.onOpApplied`.
    public func registerApplied(op: Op, inverse: Op) {
        guard let undoManager else { return }
        register(op: inverse, redoOp: op, on: undoManager)
        undoManager.setActionName("Edit")
    }

    /// Registers `op` as the action a future `undo()`/`redo()` performs; when it fires, applies
    /// `op` and re-registers `redoOp` as the next step in the opposite direction — this is what
    /// gives `UndoManager` real redo instead of a one-shot revert.
    private func register(op: Op, redoOp: Op, on undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { coordinator in
            coordinator.perform(op)
            coordinator.register(op: redoOp, redoOp: op, on: undoManager)
        }
    }
}
#endif
```

*(`undoActionName`/`redoActionName` come from `undoManager.setActionName(_:)`, which names whichever direction is about to fire — "Undo Edit" is what `undoManager.undoActionName` reads after `setActionName("Edit")`, matching AppKit's own `"Undo " + name` convention. Truthful per-op-kind names — e.g. "Undo Move Block" — are a nice-to-have follow-up: pass a `displayName` alongside `op`/`inverse` and call `setActionName(displayName)` instead of the literal `"Edit"` once `Op` has a per-case describer; not blocking for PR1.)*

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WYSIWYGUndoCoordinatorTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Wire into `SiteWindowModel`**

Extend the `windowUndoManager` didSet (`SiteWindowModel.swift:127-138`) alongside the existing fan-out:

```swift
@ObservationIgnored
weak var windowUndoManager: UndoManager? {
    didSet {
        chat?.editUndoCoordinator.undoManager = windowUndoManager
        contentUndoCoordinator.undoManager = windowUndoManager
        preview.wysiwygCanvas?.undoCoordinator.undoManager = windowUndoManager
    }
}
```

Add `let undoCoordinator: WYSIWYGUndoCoordinator` to `WYSIWYGCanvasController` (Task 7's file), constructed in `init` with `perform: { [weak self] op in Task { await self?.submit(op) } }`, and call `undoCoordinator.registerApplied(op:inverse:)` from inside `submit(_:)`'s `.applied` case instead of (or alongside) firing `onOpApplied` — reconcile with Task 7's `onOpApplied` closure by having the controller's own `init` set `onOpApplied = { [weak self] op, inverse, _ in self?.undoCoordinator.registerApplied(op: op, inverse: inverse) }`, so `PreviewModel.enterEditMode` doesn't need to know about undo wiring at all.

- [ ] **Step 6: Run the full Swift suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGUndoCoordinator.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteCoreTests/WYSIWYGUndoCoordinatorTests.swift
git commit -m "feat(#1225): register WYSIWYG ops for real NSUndoManager undo/redo"
```

---

### Task 10: Format menu — ⌘B/⌘I/⌘K on the canvas selection

**Files:**
- Modify: `Sources/AnglesiteApp/EditorFocusRegistry.swift` (new `.wysiwygCanvas` `Focus` case)
- Modify: `Sources/AnglesiteApp/FormatCommands.swift` (Strong/Emphasis/Add Link buttons check both editors)
- Modify: `JS/wysiwyg-engine/src/rich-text.ts` (new `applyFormat` method)
- Test: `JS/wysiwyg-engine/test/rich-text.test.ts` (extend existing suite)

**Interfaces:**
- Consumes: `EditorFocusRegistry.Weak<T>` (existing); `RichTextEditor#activeElement`, `#commit()` (existing, `JS/wysiwyg-engine/src/rich-text.ts:211-316`).
- Produces: `EditorFocusRegistry.Focus.wysiwygCanvas(Weak<WYSIWYGCanvasController>)`; `WYSIWYGCanvasController.applyFormat(_ command: String)` (posts to the bridge); `RichTextEditor.applyFormat(_ command: "strong" | "em" | "link")`.

Follows `EditorFocusRegistry`'s existing precedent, not a bare `@FocusedValue` — the registry exists specifically because a plain focused-value can't disambiguate two editors live in one window (its own doc comment, `EditorFocusRegistry.swift:8-13`), which is exactly the canvas-plus-inspector-text-field shape PR2 introduces. **⌘K (code) is descoped from this task**: `strong`/`em`/`link` map directly onto WebKit's still-supported `document.execCommand("bold"/"italic"/"createLink")` inside the block's `contenteditable` region, reusing `RichTextEditor`'s existing `runsFromElement`/`#commit()` serialization with zero new run-splitting logic; inline `code` has no native `execCommand` equivalent and needs selection-aware `Range` manipulation — flag it as a follow-up in the PR description rather than guessing at exact edge-case behavior here.

- [ ] **Step 1: Write the failing JS test**

Add to `JS/wysiwyg-engine/test/rich-text.test.ts` (follow the existing file's setup pattern — a `FixtureHost`-backed engine and a JSDOM contenteditable block element):

```typescript
it("applyFormat('strong') toggles bold on the current selection and commits", () => {
  // ... existing suite's setup: `editor.enter(blockId, root)` on a block whose text is
  // fully selected via `window.getSelection()` ...
  editor.applyFormat("strong");
  expect(activeElement.innerHTML).toContain("<b>");
  // ... existing suite's assertion pattern for a debounced commit firing an editText op ...
});
```

*(Match this test's exact selection-setup and commit-assertion boilerplate to whatever `rich-text.test.ts`'s existing `enter()`/commit tests already do — open the file first; don't duplicate a different pattern.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `applyFormat` doesn't exist yet.

- [ ] **Step 3: Add `applyFormat` to `RichTextEditor`**

Add to the `RichTextEditor` class (`JS/wysiwyg-engine/src/rich-text.ts`, alongside `#commit()` at lines 302-315):

```typescript
/**
 * Toggles inline formatting on the current DOM selection within the active block and commits
 * the result. `strong`/`em`/`link` reuse WebKit's still-supported `execCommand` — zero new
 * selection-splitting logic, since `#commit()` already serializes whatever DOM `execCommand`
 * produces via `runsFromElement`. `href` is required for `link` (empty string clears/no-ops).
 */
applyFormat(command: "strong" | "em" | "link", href?: string): void {
  if (!this.#activeElement) return;
  switch (command) {
    case "strong":
      document.execCommand("bold");
      break;
    case "em":
      document.execCommand("italic");
      break;
    case "link":
      document.execCommand("createLink", false, href ?? "");
      break;
  }
  this.#commit();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS

- [ ] **Step 5: Wire the Swift side**

Add to `EditorFocusRegistry.Focus` (`Sources/AnglesiteApp/EditorFocusRegistry.swift`):

```swift
enum Focus {
    case markdown(Weak<MarkdownEditorController>)
    case plainText(isPresented: Binding<Bool>)
    case wysiwygCanvas(Weak<WYSIWYGCanvasController>)
}
```

Add to `WYSIWYGCanvasController` (Task 7's file) — a weak `webView` reference (needed to call back into the page; import `WebKit`) plus the format method:

```swift
/// Set by `PreviewView`'s `onWebView` callback (Task 8) once the underlying `WKWebView` exists.
/// Weak: the view owns the web view's lifetime, matching `PreviewModel.webView`'s own pattern.
weak var webView: WKWebView?

func applyFormat(_ command: String, href: String? = nil) {
    var call = "window.__anglesiteWysiwygRichTextEditor?.applyFormat(\"\(command)\""
    if let href { call += ", \"\(href)\"" }
    call += ")"
    webView?.evaluateJavaScript(call)
}
```

Update Task 8's `onWebView` wiring (`SiteWindow.previewPane(for:)`) to also set this: `onWebView: { [preview = model.preview] webView in preview.webView = webView; preview.wysiwygCanvas?.webView = webView }`.

*(`window.__anglesiteWysiwygRichTextEditor` needs to be exposed globally by the mount script once a `RichTextEditor` is constructed — the mount script from Task 5/6 only constructs `WysiwygEngine`, not `RichTextEditor`, today. `RichTextEditor`'s constructor is `constructor(engine: WysiwygEngine, options: RichTextEditorOptions = {})` (`rich-text.ts:222`) — add `window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine)` to `mount.ts`'s `mount()` function, right after constructing `engine`, and add `WysiwygEngine`/`RichTextEditor` to `mount.ts`'s existing `declare global { interface Window { ... } }` block.)*

Modify `FormatCommands.swift`'s Font submenu buttons to check both editors:

```swift
private var wysiwygController: WYSIWYGCanvasController? {
    if case .wysiwygCanvas(let box) = registry.active { return box.value }
    return nil
}

// In the Font Menu:
Button("Strong") {
    if let wysiwygController { wysiwygController.applyFormat("strong") }
    else { markdownController?.perform(.bold) }
}
.keyboardShortcut("b")
.disabled(markdownController == nil && wysiwygController == nil)
```

Apply the same pattern to "Emphasis" (`applyFormat("em")`/`.perform(.italic)`) and "Add Link…" (`applyFormat("link", href: "")`/`.perform(.link)`).

- [ ] **Step 6: Run the Swift suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/EditorFocusRegistry.swift Sources/AnglesiteApp/FormatCommands.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "feat(#1225): wire Format menu Strong/Emphasis/Add Link to canvas selection"
```

---

### Task 11: Edit menu — Duplicate/Delete extend to canvas block selection

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:1139-1169` (`navigatorSelectionActions(for:)`)
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (add `hasKeyboardFocus`, `duplicateSelectedBlock()`, `deleteSelectedBlock()`)
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` (extend)

**Interfaces:**
- Consumes: `NavigatorSelectionActions` (existing, `FocusedSite.swift:20-24`); `WYSIWYGCanvasController.selectedBlockId`, `.model`, `.submit(_:)` (Task 7).

Per the menu-bar IA spec (`docs/superpowers/specs/2026-07-13-menubar-ia-design.md:94,232`): "⌘D Duplicate is one focus-scoped command (navigator item or editor selection)". This task extends the *existing* `NavigatorEditCommands.Duplicate` button's target rather than adding a second menu item. Delete already routes through `.onDeleteCommand` (`SiteNavigatorView.swift:29-33`) on the Navigator's `List`; the canvas host view gets its own `.onDeleteCommand` so AppKit's responder chain — not a new Commands button — decides which one fires based on real keyboard focus.

- [ ] **Step 1: Write the failing test**

```swift
@Test("duplicateSelectedBlock submits an insertBlock op for a copy of the selected block")
func duplicateSelectedBlockSubmitsInsert() async {
    let existing = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": existing])
    let transport = StubWYSIWYGHostTransport(model: initial)
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
    controller.selectedBlockId = "b1"

    await controller.duplicateSelectedBlock()

    #expect(controller.model.rootIds.count == 2)
}

@Test("deleteSelectedBlock submits a deleteBlock op and clears the selection")
func deleteSelectedBlockSubmitsDelete() async {
    let existing = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": existing])
    let transport = StubWYSIWYGHostTransport(model: initial)
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
    controller.selectedBlockId = "b1"

    await controller.deleteSelectedBlock()

    #expect(controller.model.rootIds.isEmpty)
    #expect(controller.selectedBlockId == nil)
}
```

*(These extend `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` from Task 7 — add to the same `@Suite`.)*

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `duplicateSelectedBlock`/`deleteSelectedBlock` don't exist yet.

- [ ] **Step 3: Implement the controller methods**

Add to `WYSIWYGCanvasController`:

```swift
/// True while the canvas holds real keyboard focus — distinct from `selectedBlockId != nil`,
/// which persists even when focus has moved elsewhere. Set by the canvas host view via
/// `.onDeleteCommand`'s enclosing `.focused($binding)` (Step 4); read by
/// `SiteWindow.navigatorSelectionActions(for:)` to decide which selection ⌘D acts on.
var hasKeyboardFocus = false

func duplicateSelectedBlock() async {
    guard let id = selectedBlockId, let node = model.blocks[id] else { return }
    // PR1 duplicates at the page root only — locating the block's real parent/slot to insert
    // the copy adjacent to it needs a parent-lookup helper the model doesn't expose yet; kept
    // out of scope here and flagged for a PR2 follow-up once the native palette needs the same
    // lookup for drop-target computation.
    let newId = UUID().uuidString
    let content = BlockNodeContent(kind: node.kind, componentName: node.componentName, props: node.props, slots: node.slots, sourceSpan: node.sourceSpan, richText: node.richText)
    await submit(.insertBlock(parentId: rootParentID, slot: "main", index: model.rootIds.count, newId: newId, block: content))
}

func deleteSelectedBlock() async {
    guard let id = selectedBlockId, let node = model.blocks[id], let index = model.rootIds.firstIndex(of: id) else { return }
    await submit(.deleteBlock(parentId: rootParentID, slot: "main", index: index, blockId: id, block: node))
    selectedBlockId = nil
}
```

- [ ] **Step 4: Wire into the Edit menu and responder chain**

Modify `navigatorSelectionActions(for:)` (`SiteWindow.swift:1139-1169`) to prefer canvas selection when the canvas has focus:

```swift
private func navigatorSelectionActions(for model: SiteWindowModel) -> NavigatorSelectionActions? {
    if let canvas = model.preview.wysiwygCanvas, canvas.hasKeyboardFocus, canvas.selectedBlockId != nil {
        return NavigatorSelectionActions(
            duplicate: { Task { await canvas.duplicateSelectedBlock() } },
            publish: nil, unpublish: nil)
    }
    guard model.site != nil, let navigator = model.navigator, let id = navigator.selection else {
        return nil
    }
    // ... existing navigator-selection body unchanged ...
}
```

Add `.onDeleteCommand { Task { await model.preview.wysiwygCanvas?.deleteSelectedBlock() } }` and `.focused($canvasFocused)` (mirroring `SiteNavigatorView.swift:13,29-33`'s pattern) to the canvas host view added in Task 8, syncing `canvasFocused` into `wysiwygCanvas?.hasKeyboardFocus` via `.onChange(of: canvasFocused)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS (4 tests total in the suite)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1225): extend Edit-menu Duplicate/Delete to canvas block selection"
```

*(Block "Move Up/Down" has no reserved shortcut per this session's scoping decision — ⌥⌘↑ is already claimed by the Component Editor's "Select Parent" (`docs/superpowers/specs/2026-07-13-menubar-ia-design.md:96`). PR2's native palette / right-click menu (Task 13) is where Move Up/Down gets a real affordance; no keyboard shortcut is assigned in PR1.)*

---

### Task 12: Insert menu — data-driven block palette

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (add `blockPalette`, `insertBlock(_:)`)
- Modify: `Sources/AnglesiteApp/InsertCommands.swift` (Component submenu reads the palette)
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift` (extend)

**Interfaces:**
- Produces: `struct WYSIWYGBlockPaletteEntry: Identifiable, Sendable { let id: UUID; let displayName: String; let kind: BlockKind; let componentName: String }`; `WYSIWYGCanvasController.blockPalette: [WYSIWYGBlockPaletteEntry]`; `WYSIWYGCanvasController.insertBlock(_ entry: WYSIWYGBlockPaletteEntry) async`.

The design doc's "Insert menu populated from the theme's CEM-aligned block manifest" needs a real manifest, which arrives via #1222's `get_page_model`-shaped sidecar service — not available yet (design doc §1). This task wires the *mechanism* (a data-driven Insert submenu that inserts at the current selection) against a small static palette, matching how `StubWYSIWYGHostTransport` stands in for the rest of the backend. Swapping the static palette for a real manifest fetch is a follow-up once #1222 lands — flag this in the PR description, same as the transport swap.

- [ ] **Step 1: Write the failing test**

```swift
@Test("insertBlock inserts the palette entry's component at the page root")
func insertBlockFromPalette() async {
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
    let entry = WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Paragraph", kind: .text, componentName: "p")

    await controller.insertBlock(entry)

    #expect(controller.model.rootIds.count == 1)
    let insertedId = controller.model.rootIds[0]
    #expect(controller.model.blocks[insertedId]?.componentName == "p")
}
```

*(Extends `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`, the same `@Suite` as Tasks 7 and 11.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `WYSIWYGBlockPaletteEntry`/`insertBlock` don't exist yet.

- [ ] **Step 3: Add the palette and insert method**

Add to `WYSIWYGCanvasController.swift`:

```swift
struct WYSIWYGBlockPaletteEntry: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let kind: BlockKind
    let componentName: String
}

extension WYSIWYGCanvasController {
    /// Static interim palette until #1222's sidecar model service supplies a real
    /// CEM-aligned theme manifest. Kept intentionally small — enough to exercise the Insert
    /// menu's data-driven wiring, not a stand-in for real theme block coverage.
    static let stubBlockPalette: [WYSIWYGBlockPaletteEntry] = [
        WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Paragraph", kind: .text, componentName: "p"),
        WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Heading", kind: .text, componentName: "h2"),
    ]
}
```

Add a stored property and method to the main class body:

```swift
let blockPalette: [WYSIWYGBlockPaletteEntry] = WYSIWYGCanvasController.stubBlockPalette

func insertBlock(_ entry: WYSIWYGBlockPaletteEntry) async {
    let newId = UUID().uuidString
    let content = BlockNodeContent(kind: entry.kind, componentName: entry.componentName, props: [:], slots: [:], sourceSpan: [0, 0])
    await submit(.insertBlock(parentId: rootParentID, slot: "main", index: model.rootIds.count, newId: newId, block: content))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS (5 tests total in the suite)

- [ ] **Step 5: Wire the Insert menu**

Replace `InsertCommands.swift`'s `Menu("Component") { ... }` block (currently `PlannedItem("Component Gallery…")` + the live `New Component…` button) to also list the palette when a canvas is focused:

```swift
Menu("Component") {
    PlannedItem("Component Gallery…")

    Button("New Component…") {
        actions?.newComponent()
    }
    .disabled(actions == nil)

    if let canvas = wysiwygCanvas {
        Divider()
        ForEach(canvas.blockPalette) { entry in
            Button(entry.displayName) {
                Task { await canvas.insertBlock(entry) }
            }
        }
    }
}
```

Add `@FocusedValue(\.preview) private var preview` to `InsertCommands` (the existing `\.preview` focused value already publishes `PreviewModel` per `PreviewNavigationCommands.swift:4-11`, set via `.focusedSceneValue(\.preview, model.preview)` at `SiteWindow.swift:167`) and a computed `private var wysiwygCanvas: WYSIWYGCanvasController? { preview?.wysiwygCanvas }`.

- [ ] **Step 6: Run the Swift suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/InsertCommands.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1225): wire Insert menu to a data-driven block palette"
```

---

### Task 13: Right-click block context menu (real `NSMenu`)

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGBlockContextMenu.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (hit-test message handling)
- Modify: `JS/wysiwyg-engine/src/host/mount.ts` (post a `context-menu` message on contextmenu events)
- Test: `Tests/AnglesiteAppTests/WYSIWYGBlockContextMenuTests.swift`

**Interfaces:**
- Consumes: `hitTest(point:doc:)` (existing, `JS/wysiwyg-engine/src/engine.ts:57-59`); `NSMenuItem`/`NSMenu` (AppKit, following `AnglesiteApp.swift:78-97`'s Dock-menu pattern — the only existing native `NSMenu` construction in the codebase).
- Produces: `WYSIWYGBlockContextMenu.build(for blockId: BlockId, controller: WYSIWYGCanvasController) -> NSMenu`.

Never a web context menu — the engine hit-tests (already implemented, `WysiwygEngine.hitTest`) and the host builds a real `NSMenu`, per spec §8.1.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AppKit
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("WYSIWYGBlockContextMenu")
@MainActor
struct WYSIWYGBlockContextMenuTests {
    @Test("builds a menu with Duplicate and Delete items targeting the given block")
    func buildsDuplicateAndDelete() {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))

        let menu = WYSIWYGBlockContextMenu.build(for: "b1", controller: controller)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("Duplicate"))
        #expect(titles.contains("Delete"))
    }

    @Test("selecting Duplicate sets the controller's selection to the target block first")
    func duplicateSelectsTargetFirst() {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        controller.selectedBlockId = nil

        let menu = WYSIWYGBlockContextMenu.build(for: "b1", controller: controller)
        let duplicateItem = menu.items.first { $0.title == "Duplicate" }
        _ = duplicateItem?.target?.perform(duplicateItem?.action, with: duplicateItem)

        #expect(controller.selectedBlockId == "b1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WYSIWYGBlockContextMenuTests`
Expected: FAIL — `WYSIWYGBlockContextMenu` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteApp/WYSIWYGBlockContextMenu.swift
import AppKit

/// A real `NSMenu` for a right-clicked block, built from the engine's hit-test result — never a
/// web context menu (spec §8.1). Follows the target/action + `representedObject` convention
/// already used for the app's Dock menu (`AnglesiteApp.swift:78-97`), the only prior `NSMenu`
/// construction in this codebase.
@MainActor
enum WYSIWYGBlockContextMenu {
    /// Boxes the controller + block id together as the `representedObject` every item shares,
    /// since `NSMenuItem.representedObject` takes a single `Any`.
    private final class Context {
        let controller: WYSIWYGCanvasController
        let blockId: BlockId
        init(controller: WYSIWYGCanvasController, blockId: BlockId) {
            self.controller = controller
            self.blockId = blockId
        }
    }

    static func build(for blockId: BlockId, controller: WYSIWYGCanvasController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let context = Context(controller: controller, blockId: blockId)
        let target = Target()

        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(Target.duplicate(_:)), keyEquivalent: "")
        duplicate.target = target
        duplicate.representedObject = context
        menu.addItem(duplicate)

        let delete = NSMenuItem(title: "Delete", action: #selector(Target.delete(_:)), keyEquivalent: "")
        delete.target = target
        delete.representedObject = context
        menu.addItem(delete)

        // `target` (an NSObject, needed for #selector/Objective-C dispatch) must outlive the
        // menu's lifetime on screen — stash it as an associated object on the menu itself so it
        // isn't deallocated the instant `build` returns.
        objc_setAssociatedObject(menu, &targetAssociationKey, target, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    private final class Target: NSObject {
        @objc func duplicate(_ sender: NSMenuItem) {
            guard let context = sender.representedObject as? Context else { return }
            context.controller.selectedBlockId = context.blockId
            Task { await context.controller.duplicateSelectedBlock() }
        }

        @objc func delete(_ sender: NSMenuItem) {
            guard let context = sender.representedObject as? Context else { return }
            context.controller.selectedBlockId = context.blockId
            Task { await context.controller.deleteSelectedBlock() }
        }
    }
}

private var targetAssociationKey: UInt8 = 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WYSIWYGBlockContextMenuTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Wire hit-test reporting from JS and present the menu**

Add a `context-menu` message posted on the engine's contentEditable canvas root's native `contextmenu` DOM event in `mount.ts`:

```typescript
document.addEventListener("contextmenu", (event) => {
  const engine = window.__anglesiteWysiwygEngine;
  if (!engine) return;
  const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
  if (!blockId) return;
  event.preventDefault();
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});
```

Extend `WYSIWYGOpsDispatcher.DispatchResult` (Task 4's file) with a third case and matching dispatch branch:

```swift
// Add to DispatchResult:
case contextMenu(blockId: BlockId, point: CGPoint)

// Add to dispatch(body:via:)'s switch, alongside "submit-op":
case "context-menu":
    guard let blockId = dict["blockId"] as? String,
          let x = dict["x"] as? Double, let y = dict["y"] as? Double
    else {
        return .rejected(.envelopeDecode("could not decode context-menu fields"))
    }
    return .contextMenu(blockId: blockId, point: CGPoint(x: x, y: y))
```

Add an `onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)?` parameter to `WYSIWYGScriptHandler`'s init (`Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`, default `nil`), and a matching `case .contextMenu(let blockId, let point): onContextMenu?(blockId, point)` branch in `userContentController(_:didReceive:)`'s switch (no reply needed — no `evaluateJavaScript` call for this case, unlike `.opResult`).

Wire it from `PreviewView`, passing a closure that builds and pops up the menu at the reported point (already in the web view's own coordinate space, since `event.clientX/clientY` in `mount.ts` are relative to the page viewport, which WKWebView renders 1:1 into its own bounds):

```swift
let wysiwygHandler = wysiwygTransport.map { transport in
    WYSIWYGScriptHandler(transport: transport) { blockId, point in
        guard let controller = transport as? WYSIWYGCanvasController, let webView else { return }
        let menu = WYSIWYGBlockContextMenu.build(for: blockId, controller: controller)
        menu.popUp(positioning: nil, at: point, in: webView)
    }
}
```

*(`WYSIWYGScriptHandler`'s init signature grows an `onContextMenu` parameter — update its call site above accordingly; the closure form shown here assumes `webView` is captured after `WKWebView(frame:configuration:)` is constructed later in `makeNSView`, so this handler construction may need to move after that line, or `webView` threaded in via a mutable capture set post-construction — match whichever `makeNSView` already does for `onWebView`'s similar post-construction wiring.)*

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGBlockContextMenu.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift Sources/AnglesiteApp/PreviewView.swift JS/wysiwyg-engine/src/host/mount.ts Tests/AnglesiteAppTests/WYSIWYGBlockContextMenuTests.swift
git commit -m "feat(#1225): right-click block shows a real NSMenu from engine hit-test"
```

---

### Task 14: Fix `RichTextEditor`'s post-op reconnect gap (slice 3 known limitation a)

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts`
- Test: `JS/wysiwyg-engine/test/rich-text.test.ts` (extend)

**Interfaces:**
- Consumes: `WysiwygEngine.onEvent` (existing, `engine.ts:73-76`); `RichTextEditor#activeBlockId`, `#activeElement` (existing).

Confirmed by direct read: `RichTextEditor` never subscribes to `engine.onEvent` anywhere today (design doc §7a's documented gap). Any applied op makes `BreakpointCanvas` re-render the whole frame document (`breakpoints.ts:76-82`), which can disconnect the DOM node `RichTextEditor.#activeElement` points at with nothing telling it to reattach. This task adds the missing subscription.

- [ ] **Step 1: Write the failing test**

```typescript
it("reattaches to the replaced DOM node after an applied op re-renders the block", async () => {
  // ... existing suite's setup: engine + FixtureHost + editor.enter(blockId, root) ...
  const original = editor.activeElementForTesting; // exposed in Step 3
  // Simulate the host's whole-subtree re-render replacing the block's element with a fresh node
  // carrying the same data-block-id — the exact failure mode breakpoints.ts's #render triggers.
  const replacement = document.createElement("p");
  replacement.setAttribute("data-block-id", blockId);
  replacement.textContent = "hi";
  original.replaceWith(replacement);

  await engine.submit({ kind: "setProp", blockId, propName: "x", value: "y", previousValue: "z" });

  expect(editor.activeElementForTesting).toBe(replacement);
});
```

*(Match the exact `enter()`/engine-construction boilerplate already in `rich-text.test.ts`; this extends the same suite Task 10 added a case to.)*

- [ ] **Step 2: Run test to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: FAIL — `RichTextEditor` doesn't reattach; `activeElementForTesting` doesn't exist yet.

- [ ] **Step 3: Subscribe to engine events and reattach**

Add to `RichTextEditor`'s constructor/`enter()` region (`rich-text.ts:211-255`):

```typescript
export class RichTextEditor {
  #engine: WysiwygEngine;
  // ... existing fields ...
  #unsubscribeEngine: (() => void) | null = null;

  /** Test-only accessor for the currently-attached DOM node. */
  get activeElementForTesting(): HTMLElement | null {
    return this.#activeElement;
  }

  enter(blockId: BlockId, root: ParentNode = document): void {
    // ... existing lookup + listener-wiring body (unchanged) ...
    this.#unsubscribeEngine?.();
    this.#unsubscribeEngine = this.#engine.onEvent((event) => {
      if (!("model" in event) || !event.model) return;
      if (this.#activeBlockId === null) return;
      // Any event carrying a model is a potential whole-subtree re-render (breakpoints.ts's
      // #onEngineEvent triggers on exactly these) — re-resolve the live element for the block
      // we're editing and reattach if its identity changed.
      const current = findBlockElement(this.#activeBlockId, root);
      if (current && current !== this.#activeElement) {
        this.#activeElement?.removeEventListener("input", this.#onInput);
        this.#activeElement?.removeEventListener("blur", this.#onBlur);
        this.#activeElement?.removeEventListener("keydown", this.#onKeydown);
        this.#activeElement = current;
        current.addEventListener("input", this.#onInput);
        current.addEventListener("blur", this.#onBlur);
        current.addEventListener("keydown", this.#onKeydown);
      }
    });
  }

  exit(): void {
    this.#unsubscribeEngine?.();
    this.#unsubscribeEngine = null;
    // ... existing exit body ...
  }
}
```

*(Splice these additions into the exact existing `enter()`/`exit()` bodies — don't duplicate the listener-wiring lines that already exist there; factor them into a small private `#attach(_ element: HTMLElement)` helper shared by both `enter()`'s initial attach and the reattach path above, since the same three `addEventListener` calls now happen in two places.)*

- [ ] **Step 4: Run test to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- rich-text`
Expected: PASS

- [ ] **Step 5: Run the full JS suite and typecheck**

Run: `cd JS/wysiwyg-engine && npm run typecheck && npm run lint && npm test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "fix(#1225): reattach RichTextEditor after a whole-subtree re-render"
```

---

### Task 15: End-to-end integration test + full suite verification

**Files:**
- Create: `Tests/AnglesiteAppTests/WYSIWYGPlumbingIntegrationTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-14.

Proves the full vertical slice: a menu-triggered op crosses the (in-process, same-target) dispatcher, applies against the stub, updates the controller's model, and registers on a real `UndoManager` with working undo/redo — the milestone this PR exists to deliver.

- [ ] **Step 1: Write the integration test**

```swift
import Testing
import Foundation
@testable import AnglesiteApp
@testable import AnglesiteCore

@Suite("WYSIWYG plumbing end-to-end")
@MainActor
struct WYSIWYGPlumbingIntegrationTests {
    @Test("insertBlock via the controller round-trips through the stub and is undoable/redoable")
    func insertRoundTripsAndUndoes() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller.undoCoordinator.undoManager = undoManager

        let op = Op.insertBlock(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        _ = await controller.submit(op)
        #expect(controller.model.rootIds == ["b1"])

        undoManager.undo()
        // The undo coordinator's Performer dispatches submit() on a Task — give it a run-loop
        // turn to complete before asserting, matching the async-perform pattern.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.rootIds.isEmpty)

        undoManager.redo()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.rootIds == ["b1"])
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter WYSIWYGPlumbingIntegrationTests`
Expected: PASS

*(If the `Task.sleep`-based synchronization proves flaky in CI, replace it with an explicit `await`-able completion signal on `WYSIWYGUndoCoordinator`'s `Performer` — e.g. have `registerApplied`'s handler `await` an async `Performer` directly instead of dispatching a detached `Task`, which the deflake memory for this repo prefers ("event-driven waits", not per-test sleep tuning) over a fixed delay.)*

- [ ] **Step 3: Run the full Swift and JS suites**

Run:
```bash
swift test --package-path .
```
```bash
cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test
```
Expected: both PASS, no regressions anywhere in the repo.

- [ ] **Step 4: Verify the app builds**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Tests/AnglesiteAppTests/WYSIWYGPlumbingIntegrationTests.swift
git commit -m "test(#1225): add end-to-end WYSIWYG plumbing integration test"
```

---

## PR description notes (not a task — carry into the PR body)

- Follow `CONTRIBUTING.md` ▸ "Commits and pull requests": use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings, `Closes #1225` only once all of PR1-3 land (or omit the closing keyword on this PR and use it on PR3, since #1225 covers all three — confirm with the issue owner which PR should carry the closing keyword).
- Flag explicitly in the PR body: (1) `Resources/wysiwyg-engine/` needs `project.yml`'s prebuild script list updated to also run `scripts/build-wysiwyg-engine.sh`, if Task 6 didn't get write access to make that change; (2) ⌘K (inline code format) and block Move Up/Down are intentionally unshortcutted in this PR, per Task 10/11's scoping notes; (3) the real sidecar-backed transport swap is a follow-up PR once #1222 lands.
