# WYSIWYG Mac Host Chrome — PR2 (Panels) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chrome around the WYSIWYG canvas native, per design doc §4 (issue #1588, PR2 of 3): a native inspector for typed block props, a native palette (source list) with drag-in reorder and cross-boundary insert, Finder/Photos drag-in asset ingestion, semantic paste + block copy, and document conventions (window title/proxy icon, edited-dot, native find bar, `.toolbar(id:)`).

**Architecture:** PR1 (#1400, merged) built the ops bridge, `WYSIWYGCanvasController` (the `@Observable` app-side orchestrator owned by `PreviewModel`), and `StubWYSIWYGHostTransport`. This plan builds on top without touching the bridge's wire protocol except two additive message types (`selection-changed` from JS, no new native→JS ones — drop-target computation reuses the existing `evaluateJavaScript` pull pattern `ComponentEditorCanvasPane` already established for its own canvas). The canvas's current block selection — today set only by native menu commands — first gets a real round-trip from the JS engine's own click-to-select gesture (Task 1-3), because the inspector, palette drop-target math, and nested-block duplicate/delete all depend on knowing which block (including nested ones) is selected. Everything else layers on top: inspector (Tasks 4-8), palette + drag/drop (Tasks 9-11), Finder/Photos ingestion (Tasks 12-13), semantic paste + copy (Tasks 14-16), document conventions (Tasks 17-20).

**Tech Stack:** Swift 6.4 (`AnglesiteCore`, `AnglesiteBridgeCore`, `AnglesiteBridge`, `AnglesiteApp`/`AnglesiteAppCore` targets), Swift Testing, TypeScript (`JS/wysiwyg-engine/`), vitest, esbuild.

## Global Constraints

- Swift/SwiftUI + Apple frameworks only — no third-party dependencies (CONTRIBUTING.md).
- Process spawning stays centralized in `AnglesiteCore/ProcessSupervisor` — not touched by this plan.
- No silent failure paths — every bridge rejection/drop logs via `LogCenter` (CLAUDE.md "logs are sacred"), matching PR1's convention in `WYSIWYGScriptHandler`.
- Conventional commits, subject ≤72 chars. Per CONTRIBUTING.md's commit-scope/closing-keyword collision note, this PR does **not** close #1588 (PR3 follows), so commits use `feat(#1588): ...` (a non-closing type is fine too) — never `fix(#1588): ...`/`close`/`resolve` wording, which GitHub's linker would treat as a closing keyword on any commit that lands on `main`.
- Follow existing patterns exactly where one already exists for the same shape — this plan cites file:line precedent for every non-trivial design choice, mirroring PR1's plan.
- `StubWYSIWYGHostTransport` remains the backend — no real source write or git commit in this plan (still waiting on #1222).
- `AnglesiteCore` builds on Linux (cross-platform port, #571) — any new type there that touches `AppKit`/`SwiftUI` must be guarded with `#if canImport(AppKit)` / `#if canImport(SwiftUI)`, matching `CSSColor.swift`'s existing pattern.
- `Tests/AnglesiteAppTests` imports the app-target sources via `@testable import AnglesiteAppCore` (the SwiftPM-testable target name for `Sources/AnglesiteApp/`; confirmed via `Package.swift:328` and the existing `WYSIWYGCanvasControllerTests.swift`) — not `AnglesiteApp`.
- Deliberately out of scope for this plan (deferred, not forgotten): full multi-frame `DragReorderController`-per-breakpoint-frame support and frame-local coordinate translation (design doc's limitations (b)/(c)) — PR1's mount path is still a single document/single `WysiwygEngine`; `BreakpointCanvas` (`JS/wysiwyg-engine/src/breakpoints.ts`) is exercised only by its own e2e fixtures and is never wired to the native host. Building per-frame support now would be scaffolding for a subsystem that doesn't exist yet (YAGNI) — it's real work for whichever slice actually wires breakpoint frames into the native mount path.
- AI alt-text proposal for dropped images stays a stubbed empty string (design doc §4: "AI alt-text proposal is stubbed/no-op here — the real proposal depends on on-device AI services (slice 6, #1227)").

---

### Task 1: JS — wire click-to-select and push `selection-changed` to native

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts`
- Test: `JS/wysiwyg-engine/test/host/mount-selection.test.ts`

**Interfaces:**
- Consumes: `WysiwygEngine.hitTest(point, doc)`, `WysiwygEngine.selection.select(id)`, `WysiwygEngine.onEvent(listener)`, `EngineEvent` (`../engine.js`, all existing).
- Produces: (module-internal) `wireSelection(engine): () => void`, called from `mount()`; disposed from `disposeMounted()`.

`WysiwygEngine.selection` (`selection.ts`) and the `"selection-changed"` `EngineEvent` (`engine.ts:17`) already exist from slices 2-3, but nothing calls `selection.select(...)` on a click, and nothing posts the change to native — confirmed by grep, `selection.select(` has zero call sites outside `selection.ts` itself. Without this, `WYSIWYGCanvasController.selectedBlockId` (native) only ever gets set by menu/context-menu code, never by the owner clicking a block in the canvas — which the inspector (Task 6-8) and the generalized duplicate/delete (Task 3) both need to react to.

- [ ] **Step 1: Write the failing test**

```typescript
// JS/wysiwyg-engine/test/host/mount-selection.test.ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";

// Re-implements just enough of mount.ts's selection wiring to unit-test in isolation — mount.ts
// itself is exercised end-to-end by the existing native-host-transport tests plus this file once
// wireSelection is exported. Importing the real wireSelection keeps this from drifting.
import { __testables } from "../../src/host/mount.js";

function stubTransport(): HostTransport {
  return {
    sendOp: async (): Promise<OpResult> => ({ status: "applied", model: emptyModel() }),
    onModelUpdate: () => () => {},
  };
}

function emptyModel(): BlockModel {
  return { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };
}

describe("mount.ts selection wiring", () => {
  beforeEach(() => {
    (window as any).webkit = { messageHandlers: { wysiwyg: { postMessage: vi.fn() } } };
    document.body.innerHTML = "";
  });

  it("selecting a block posts a selection-changed message to native", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    engine.selection.select("b1");
    expect((window as any).webkit.messageHandlers.wysiwyg.postMessage).toHaveBeenCalledWith({
      type: "selection-changed",
      blockId: "b1",
    });
    dispose();
  });

  it("clicking a block element hit-tests and selects it", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    Object.defineProperty(el, "getBoundingClientRect", { value: () => ({ x: 0, y: 0, width: 10, height: 10, top: 0, left: 0, right: 10, bottom: 10 }) });
    document.body.appendChild(el);
    vi.spyOn(document, "elementFromPoint").mockReturnValue(el);

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    document.dispatchEvent(new MouseEvent("click", { clientX: 5, clientY: 5, bubbles: true }));
    expect(engine.selection.current).toBe("b1");
    dispose();
  });

  it("dispose stops forwarding further selection changes", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dispose = __testables.wireSelection(engine);
    dispose();
    const postMessage = (window as any).webkit.messageHandlers.wysiwyg.postMessage as ReturnType<typeof vi.fn>;
    postMessage.mockClear();
    engine.selection.select("b2");
    expect(postMessage).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- mount-selection`
Expected: FAIL — `__testables`/`wireSelection` don't exist yet.

- [ ] **Step 3: Implement**

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — add near the top, after the existing imports
import { hitTest } from "../hit-test.js";
```

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — add before `disposeMounted()`
/**
 * Click-to-select (spec §8.1's engine hit-testing, this time driving native block selection
 * instead of a context menu) plus the engine → native half of the selection round-trip: whenever
 * `engine.selection` changes — from this click listener, or from any other future engine-internal
 * cause — post it to native so `WYSIWYGCanvasController.selectedBlockId` (the source the native
 * inspector/palette read) stays in sync. A `document`-level click listener, not scoped to the
 * mounted canvas root, matches the existing `contextmenu` listener below for the same reason:
 * `hitTest`'s `elementFromPoint` walks up from whatever's under the cursor to the nearest
 * block-id-bearing ancestor regardless of where the click started.
 */
function wireSelection(engine: WysiwygEngine): () => void {
  const onClick = (event: MouseEvent) => {
    const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
    engine.selection.select(blockId);
  };
  document.addEventListener("click", onClick);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type !== "selection-changed") return;
    window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "selection-changed", blockId: event.blockId });
  });

  return () => {
    document.removeEventListener("click", onClick);
    unsubscribe();
  };
}

// Test-only escape hatch (vitest imports this module directly rather than going through the
// window globals mount() sets) — mirrors no existing precedent in this file because mount.ts had
// no internal functions worth unit-testing before this task; kept to the one function that needs
// it rather than exporting everything.
export const __testables = { wireSelection };
```

Now wire it into `mount()`'s lifecycle — a module-level disposer, set in `mount()`, cleared in `disposeMounted()`:

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — replace the disposeMounted function and mount() body
let disposeSelection: (() => void) | null = null;

function disposeMounted(): void {
  disposeSelection?.();
  disposeSelection = null;
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    disposeSelection = wireSelection(engine);
    return engine;
  },
  unmount(): void {
    disposeMounted();
  },
};
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd JS/wysiwyg-engine && npm test -- mount-selection`
Expected: PASS (3 tests)

- [ ] **Step 5: Typecheck, lint, and commit**

Run: `cd JS/wysiwyg-engine && npm run typecheck && npm run lint`
Expected: no errors.

```bash
git add JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/mount-selection.test.ts
git commit -m "feat(#1588): wire click-to-select and push selection-changed to native"
```

---

### Task 2: Swift — `selection-changed` bridge message + `selectedBlockId` round-trip

**Files:**
- Modify: `Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift`
- Modify: `Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`
- Modify: `Sources/AnglesiteApp/PreviewView.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift`

**Interfaces:**
- Consumes: `BlockId` (`AnglesiteCore`), Task 1's `{ type: "selection-changed", blockId }` message shape.
- Produces: `WYSIWYGOpsDispatcher.DispatchResult.selectionChanged(blockId: BlockId?)`; `WYSIWYGScriptHandler.init(transport:logCenter:onContextMenu:onSelectionChanged:)`.

Mirrors the existing `context-menu` case exactly (`WYSIWYGOpsDispatcher.swift:30-33,60-66`; `WYSIWYGScriptHandler.swift:12,30-31`) — a JS-originated, no-reply message the handler forwards to a closure instead of the transport.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift, inside the existing @Suite
@Test("dispatch decodes a selection-changed message with a block id")
func decodesSelectionChangedWithBlock() async {
    let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
    let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": "b1"], via: transport)
    guard case .selectionChanged(let blockId) = result else {
        Issue.record("expected .selectionChanged, got \(result)")
        return
    }
    #expect(blockId == "b1")
}

@Test("dispatch decodes a selection-changed message clearing the selection")
func decodesSelectionChangedCleared() async {
    let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
    let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": NSNull()], via: transport)
    guard case .selectionChanged(let blockId) = result else {
        Issue.record("expected .selectionChanged, got \(result)")
        return
    }
    #expect(blockId == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: FAIL — `DispatchResult.selectionChanged` doesn't exist yet (build error).

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift — extend DispatchResult and dispatch(body:via:)
public enum DispatchResult: Sendable {
    case opResult(requestId: String, result: OpResult)
    case contextMenu(blockId: BlockId, point: WYSIWYGPoint)
    /// `selection-changed` reported the engine's own selection state changing (a click, or any
    /// other engine-internal cause) — `blockId` is `nil` when the selection was cleared. No reply
    /// is sent back to the page, same as `contextMenu`.
    case selectionChanged(blockId: BlockId?)
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
    case "context-menu":
        guard let blockId = dict["blockId"] as? String,
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else {
            return .rejected(.envelopeDecode("could not decode context-menu fields"))
        }
        return .contextMenu(blockId: blockId, point: WYSIWYGPoint(x: x, y: y))
    case "selection-changed":
        // `blockId` is legitimately absent/null (selection cleared) — unlike context-menu's
        // required blockId, this isn't a decode failure.
        return .selectionChanged(blockId: dict["blockId"] as? String)
    default:
        return .rejected(.unknownType(typeStr))
    }
}
```

```swift
// Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift — add the callback and dispatch case
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    private let transport: any WYSIWYGHostTransport
    private let logCenter: LogCenter
    private let onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)?
    private let onSelectionChanged: (@Sendable (BlockId?) -> Void)?

    public init(
        transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared,
        onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
        onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil
    ) {
        self.transport = transport
        self.logCenter = logCenter
        self.onContextMenu = onContextMenu
        self.onSelectionChanged = onSelectionChanged
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WYSIWYGOpsDispatcher.scriptMessageNamespace else { return }
        let body = message.body
        let webView = message.webView
        let transport = self.transport
        let logCenter = self.logCenter
        let onContextMenu = self.onContextMenu
        let onSelectionChanged = self.onSelectionChanged
        Task {
            switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport) {
            case .contextMenu(let blockId, let point):
                onContextMenu?(blockId, CGPoint(x: point.x, y: point.y))
            case .selectionChanged(let blockId):
                onSelectionChanged?(blockId)
            case .opResult(let requestId, let result):
                guard let webView else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "webView deallocated before submit-op reply for id=\(requestId)")
                    return
                }
                guard let data = try? JSONEncoder().encode(result),
                      let json = String(data: data, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode OpResult for id=\(requestId)")
                    return
                }
                guard let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode requestId for id=\(requestId)")
                    return
                }
                let script = "window.__anglesiteWysiwygHost?._handleOpResult?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
            case .rejected(let reason):
                await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "rejected message: \(reason)")
            }
        }
    }
}
```

Now wire it in `PreviewView`'s handler construction — find `makeWYSIWYGHandler(for:coordinator:)` (`Sources/AnglesiteApp/PreviewView.swift`, the same place `onContextMenu` is already wired) and add the `onSelectionChanged` argument:

```swift
// Sources/AnglesiteApp/PreviewView.swift — inside makeWYSIWYGHandler, alongside the existing onContextMenu closure
WYSIWYGScriptHandler(
    transport: controller,
    onContextMenu: { [weak controller] blockId, point in
        Task { @MainActor in
            guard let controller else { return }
            WYSIWYGBlockContextMenu.build(for: blockId, controller: controller).popUp(positioning: nil, at: point, in: nil)
        }
    },
    onSelectionChanged: { [weak controller] blockId in
        Task { @MainActor in controller?.selectedBlockId = blockId }
    }
)
```

(Exact surrounding closure/capture syntax should match whatever `onContextMenu`'s wiring already does at this call site — read the existing `makeWYSIWYGHandler` body before editing so the new argument fits the established capture style rather than introducing a second convention.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGOpsDispatcherTests`
Expected: PASS (existing 2 tests + 2 new = 4)

- [ ] **Step 5: Build and commit**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

```bash
git add Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift Sources/AnglesiteApp/PreviewView.swift Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift
git commit -m "feat(#1588): round-trip canvas selection from JS into selectedBlockId"
```

---

### Task 3: Swift — parent-lookup helper; nested-block duplicate/delete

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Modify: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Consumes: `BlockModel`, `BlockId`, `ParentRef`, `rootParentID` (`AnglesiteCore`, existing).
- Produces: `WYSIWYGCanvasController.locate(_:) -> (parentId: ParentRef, slot: String, index: Int)?`; generalized `duplicateSelectedBlock()`/`deleteSelectedBlock()`.

PR1's own doc comments (`WYSIWYGCanvasController.swift:159-168,178-188`) flag exactly this: duplicate/delete only work at the page root because there's no helper to find a nested block's real parent/slot/index, and duplicate currently no-ops for a nested selection instead of duplicating it adjacent to its real position. This task adds that helper and fixes both methods — needed before the palette's drop-target math (Task 11) and the inspector (Task 6-8) can trust `selectedBlockId` to mean "the selected block, wherever it structurally lives."

This task **replaces** the existing `"duplicateSelectedBlock no-ops for a nested (non-root) block..."` test with one asserting correct nested duplication — the old no-op behavior was the documented PR1 limitation this task fixes, not a contract to preserve.

- [ ] **Step 1: Write the failing tests**

```swift
// Replace the existing "duplicateSelectedBlockNoOpsForNestedBlock" test in
// Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift with:
@Test("duplicateSelectedBlock duplicates a nested block into its real parent slot, adjacent to it")
func duplicateSelectedBlockHandlesNestedBlock() async {
    let nested = BlockNode(id: "b2", kind: .text, componentName: "span", props: [:], slots: [:], sourceSpan: [10, 20])
    let container = BlockNode(id: "b1", kind: .astro, componentName: "Container", props: [:], slots: ["main": ["b2"]], sourceSpan: [0, 30])
    let initial = BlockModel(
        path: "src/pages/index.astro", version: "v0", rootIds: ["b1"],
        blocks: ["b1": container, "b2": nested])
    let transport = StubWYSIWYGHostTransport(model: initial)
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
    controller.selectedBlockId = "b2"

    await controller.duplicateSelectedBlock()

    let parent = controller.model.blocks["b1"]
    #expect(parent?.slots["main"]?.count == 2)
    #expect(parent?.slots["main"]?.first == "b2")
}

@Test("locate finds a root block's parent/slot/index")
func locateFindsRootBlock() {
    let existing = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": existing])
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))

    let location = controller.locate("b1")

    #expect(location?.parentId == rootParentID)
    #expect(location?.index == 0)
}

@Test("locate returns nil for a block not present in the model")
func locateReturnsNilForMissingBlock() {
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))

    #expect(controller.locate("ghost") == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `locate` doesn't exist; the nested-duplicate test fails against the old root-only implementation.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — add near duplicateSelectedBlock/deleteSelectedBlock
extension WYSIWYGCanvasController {
    /// Finds `id`'s structural position in `model` — its parent (`rootParentID` for a page-root
    /// block), containing slot, and index within that slot — by walking every block's `slots`
    /// dictionary. `nil` means `id` isn't reachable from `model.rootIds` or any block's slots at
    /// all (already deleted, or a stale selection). This is the lookup PR1's duplicate/delete
    /// deliberately deferred (see those methods' own doc comments) rather than root-only guard
    /// clauses re-derived ad hoc at each call site.
    func locate(_ id: BlockId) -> (parentId: ParentRef, slot: String, index: Int)? {
        if let index = model.rootIds.firstIndex(of: id) {
            return (rootParentID, "main", index)
        }
        for (parentId, node) in model.blocks {
            for (slot, children) in node.slots {
                if let index = children.firstIndex(of: id) {
                    return (parentId, slot, index)
                }
            }
        }
        return nil
    }
}
```

Replace `duplicateSelectedBlock()` and `deleteSelectedBlock()`:

```swift
    /// The Edit-menu Duplicate button's canvas-focused target (#1225 Task 11, generalized #1588
    /// Task 3). Duplicates into the block's real parent/slot, immediately after it — `locate(_:)`
    /// is what makes that possible; PR1 could only insert at the page root because this lookup
    /// didn't exist yet.
    func duplicateSelectedBlock() async {
        guard let id = selectedBlockId, let node = model.blocks[id], let location = locate(id) else { return }
        let newId = UUID().uuidString
        let content = BlockNodeContent(
            kind: node.kind, componentName: node.componentName, props: node.props,
            slots: node.slots, sourceSpan: node.sourceSpan, richText: node.richText)
        await submit(.insertBlock(parentId: location.parentId, slot: location.slot, index: location.index + 1, newId: newId, block: content))
    }

    /// The canvas's own `.onDeleteCommand` target (#1225 Task 11, generalized #1588 Task 3) —
    /// reachable only when the canvas holds real keyboard focus (`hasKeyboardFocus`). Now handles
    /// nested blocks via `locate(_:)`, same reasoning as `duplicateSelectedBlock()` above.
    func deleteSelectedBlock() async {
        guard let id = selectedBlockId, let node = model.blocks[id], let location = locate(id) else { return }
        await submit(.deleteBlock(parentId: location.parentId, slot: location.slot, index: location.index, blockId: id, block: node))
        selectedBlockId = nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS (all tests in the suite, including the previously-passing root-level duplicate/delete tests — unchanged behavior for root blocks).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1588): add parent-lookup helper, fix nested-block duplicate/delete"
```

---

### Task 4: Swift — block prop descriptor types

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGPropDescriptor.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGPropDescriptorTests.swift`

**Interfaces:**
- Produces: `WYSIWYGPropEditorKind` (`Codable, Equatable, Sendable` enum: `.text/.number/.boolean/.color/.enumeration`); `WYSIWYGPropDescriptor` (`Codable, Equatable, Sendable` struct: `name, label, kind, enumOptions`).

There is currently no manifest type describing a block's editable props at all — `WYSIWYGBlockPaletteEntry` (`WYSIWYGCanvasController.swift:325-330`) is 4 fields with no prop schema, and `PageModel.BlockInfo` (the real CEM-manifest projection, blocked on #1222) has no `props` field either. This is new vocabulary the native inspector needs; it lives in `AnglesiteCore` (portable, `Codable`) rather than `AnglesiteApp` because nothing about it is SwiftUI/WebKit-specific.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGPropDescriptor")
struct WYSIWYGPropDescriptorTests {
    @Test("round-trips through Codable for every kind")
    func codableRoundTrip() throws {
        let descriptors = [
            WYSIWYGPropDescriptor(name: "title", label: "Title", kind: .text),
            WYSIWYGPropDescriptor(name: "weight", label: "Weight", kind: .number),
            WYSIWYGPropDescriptor(name: "emphasis", label: "Emphasis", kind: .boolean),
            WYSIWYGPropDescriptor(name: "accentColor", label: "Accent Color", kind: .color),
            WYSIWYGPropDescriptor(name: "level", label: "Level", kind: .enumeration, enumOptions: ["1", "2", "3"]),
        ]
        for descriptor in descriptors {
            let data = try JSONEncoder().encode(descriptor)
            #expect(try JSONDecoder().decode(WYSIWYGPropDescriptor.self, from: data) == descriptor)
        }
    }

    @Test("enumOptions defaults to empty for non-enum kinds")
    func enumOptionsDefaultsEmpty() {
        let descriptor = WYSIWYGPropDescriptor(name: "title", label: "Title", kind: .text)
        #expect(descriptor.enumOptions.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGPropDescriptorTests`
Expected: FAIL — types don't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGPropDescriptor.swift
import Foundation

/// Which native system control a block prop's inspector row uses (design doc §4: "typed block
/// props using system controls: steppers, color wells with the system color panel, pop-up
/// buttons"). Real prop schemas will come from #1222's CEM-aligned theme manifest once it exists;
/// until then, `WYSIWYGBlockPaletteEntry.props` (Task 5) carries a small static stand-in built
/// from this vocabulary, same "interim, not a fake final answer" posture PR1 took for the block
/// palette itself.
public enum WYSIWYGPropEditorKind: String, Codable, Equatable, Sendable {
    case text
    case number
    case boolean
    case color
    case enumeration = "enum"
}

/// One editable prop on a block kind, and how to render/commit it. `enumOptions` is only
/// meaningful for `.enumeration` — the fixed set of allowed string values a pop-up button offers.
public struct WYSIWYGPropDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let label: String
    public let kind: WYSIWYGPropEditorKind
    public let enumOptions: [String]

    public init(name: String, label: String, kind: WYSIWYGPropEditorKind, enumOptions: [String] = []) {
        self.name = name
        self.label = label
        self.kind = kind
        self.enumOptions = enumOptions
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGPropDescriptorTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGPropDescriptor.swift Tests/AnglesiteCoreTests/WYSIWYGPropDescriptorTests.swift
git commit -m "feat(#1588): add WYSIWYGPropDescriptor block-prop editor vocabulary"
```

---

### Task 5: Swift — extend the block palette with prop schemas

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGPropDescriptor`, `WYSIWYGPropEditorKind` (Task 4).
- Produces: `WYSIWYGBlockPaletteEntry.props: [WYSIWYGPropDescriptor]` (new field, defaulted); an expanded `stubBlockPalette` with 4 entries (Paragraph, Heading, Callout, Image) exercising every `WYSIWYGPropEditorKind`.

Still an "interim stand-in" per PR1's own doc comment (`WYSIWYGCanvasController.swift:332-335`) — this task doesn't claim to be the real CEM manifest, it just gives the native inspector (Tasks 6-8) real data to render against instead of every block having zero editable props.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
@Test("stubBlockPalette's Callout entry exposes text, color, and boolean prop descriptors")
func stubPaletteCalloutHasTypedProps() {
    let callout = WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == "Callout" }
    #expect(callout?.props.map(\.kind).sorted(by: { $0.rawValue < $1.rawValue }) == [.boolean, .color, .text].sorted(by: { $0.rawValue < $1.rawValue }))
}

@Test("stubBlockPalette's Heading entry exposes an enum level prop")
func stubPaletteHeadingHasEnumLevel() {
    let heading = WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == "h2" }
    #expect(heading?.props.first?.kind == .enumeration)
    #expect(heading?.props.first?.enumOptions == ["1", "2", "3", "4"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `WYSIWYGBlockPaletteEntry` has no `props` field, `Callout`/`Image` entries don't exist.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — replace the WYSIWYGBlockPaletteEntry struct and stubBlockPalette
struct WYSIWYGBlockPaletteEntry: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let kind: BlockKind
    let componentName: String
    let props: [WYSIWYGPropDescriptor]

    init(id: UUID, displayName: String, kind: BlockKind, componentName: String, props: [WYSIWYGPropDescriptor] = []) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.componentName = componentName
        self.props = props
    }
}

extension WYSIWYGCanvasController {
    /// Static interim palette until #1222's sidecar model service supplies a real CEM-aligned
    /// theme manifest — now with `props` (#1588 Task 5) so the native inspector (Task 6-8) has
    /// real per-kind schemas to render, covering every `WYSIWYGPropEditorKind`.
    static let stubBlockPalette: [WYSIWYGBlockPaletteEntry] = [
        WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Paragraph", kind: .text, componentName: "p"),
        WYSIWYGBlockPaletteEntry(
            id: UUID(), displayName: "Heading", kind: .text, componentName: "h2",
            props: [WYSIWYGPropDescriptor(name: "level", label: "Level", kind: .enumeration, enumOptions: ["1", "2", "3", "4"])]),
        WYSIWYGBlockPaletteEntry(
            id: UUID(), displayName: "Callout", kind: .astro, componentName: "Callout",
            props: [
                WYSIWYGPropDescriptor(name: "title", label: "Title", kind: .text),
                WYSIWYGPropDescriptor(name: "accentColor", label: "Accent Color", kind: .color),
                WYSIWYGPropDescriptor(name: "emphasis", label: "Emphasis", kind: .boolean),
            ]),
        WYSIWYGBlockPaletteEntry(
            id: UUID(), displayName: "Image", kind: .astro, componentName: "img",
            props: [
                WYSIWYGPropDescriptor(name: "src", label: "Source", kind: .text),
                WYSIWYGPropDescriptor(name: "alt", label: "Alt Text", kind: .text),
            ]),
    ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1588): give the interim block palette prop schemas"
```

---

### Task 6: Swift — `WYSIWYGInspectorModel`

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGInspectorModel.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGInspectorModelTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGCanvasController.submit(_:)`, `.model`, `WYSIWYGPropDescriptor`, `WYSIWYGBlockPaletteEntry.props` (Tasks 4-5).
- Produces: `WYSIWYGInspectorModel` (`@MainActor @Observable final class`): `init(controller:blockId:)`, `descriptors: [WYSIWYGPropDescriptor]`, `stringValue(for:)`/`setString(_:for:)`, `numberValue(for:)`/`setNumber(_:for:)`, `boolValue(for:)`/`setBool(_:for:)`.

Follows `TypedEntryEditorModel`'s per-field-binding-method pattern (`TypedEntryEditorModel.swift:296-337`) rather than raw `@Bindable` keypaths, but — unlike that model — commits are per-edit (`Op.setProp` through `submit(_:)`), not buffered-until-Save: the WYSIWYG canvas has no separate "Save" step (design doc §1, everything applies live against the stub transport), matching how `ComponentStyleInspectorPane`'s color/text edits commit without a Save button too.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("WYSIWYGInspectorModel")
@MainActor
struct WYSIWYGInspectorModelTests {
    static func makeController(componentName: String, props: [String: PropValue] = [:]) -> (WYSIWYGCanvasController, BlockId) {
        let node = BlockNode(id: "b1", kind: .astro, componentName: componentName, props: props, slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        return (controller, "b1")
    }

    @Test("descriptors resolves from the palette entry matching the block's componentName")
    func descriptorsResolveFromPalette() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.map(\.name).sorted() == ["accentColor", "emphasis", "title"])
    }

    @Test("descriptors is empty for a component with no palette match")
    func descriptorsEmptyForUnknownComponent() {
        let (controller, blockId) = Self.makeController(componentName: "SomeUnknownWidget")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.isEmpty)
    }

    @Test("setString submits a setProp op and stringValue reflects the committed result")
    func setStringCommitsAndReflects() async {
        let (controller, blockId) = Self.makeController(componentName: "Callout", props: ["title": .string("old")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        model.setString("new", for: "title")
        try? await Task.sleep(nanoseconds: 10_000_000) // let the fire-and-forget Task run

        #expect(model.stringValue(for: "title") == "new")
    }

    @Test("boolValue defaults to false for a prop not yet set on the block")
    func boolValueDefaultsFalse() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.boolValue(for: "emphasis") == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGInspectorModelTests`
Expected: FAIL — `WYSIWYGInspectorModel` doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGInspectorModel.swift
import Foundation
import Observation
import AnglesiteCore

/// The native inspector's model for one selected WYSIWYG block (#1588 Task 6) — the WYSIWYG
/// analog of `TypedEntryEditorModel`'s per-field binding methods (`TypedEntryEditorModel.swift`),
/// but committing per-edit through `Op.setProp` rather than buffering until an explicit Save: the
/// canvas has no Save step, everything applies live (design doc §1).
@MainActor
@Observable
final class WYSIWYGInspectorModel {
    let controller: WYSIWYGCanvasController
    let blockId: BlockId

    init(controller: WYSIWYGCanvasController, blockId: BlockId) {
        self.controller = controller
        self.blockId = blockId
    }

    private var node: BlockNode? { controller.model.blocks[blockId] }

    /// The editable props for this block's kind, resolved from the interim palette (Task 5) by
    /// matching `componentName` — real prop schemas arrive with #1222's CEM manifest.
    var descriptors: [WYSIWYGPropDescriptor] {
        guard let node else { return [] }
        return WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == node.componentName }?.props ?? []
    }

    func stringValue(for name: String) -> String {
        guard case .string(let value)? = node?.props[name] else { return "" }
        return value
    }

    func setString(_ value: String, for name: String) {
        Task { await commit(name: name, value: .string(value)) }
    }

    func numberValue(for name: String) -> Double {
        guard case .number(let value)? = node?.props[name] else { return 0 }
        return value
    }

    func setNumber(_ value: Double, for name: String) {
        Task { await commit(name: name, value: .number(value)) }
    }

    func boolValue(for name: String) -> Bool {
        guard case .bool(let value)? = node?.props[name] else { return false }
        return value
    }

    func setBool(_ value: Bool, for name: String) {
        Task { await commit(name: name, value: .bool(value)) }
    }

    private func commit(name: String, value: PropValue) async {
        let previous = node?.props[name] ?? .null
        await controller.submit(.setProp(blockId: blockId, propName: name, value: value, previousValue: previous))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGInspectorModelTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGInspectorModel.swift Tests/AnglesiteAppTests/WYSIWYGInspectorModelTests.swift
git commit -m "feat(#1588): add WYSIWYGInspectorModel for typed block prop editing"
```

---

### Task 7: Swift — `WYSIWYGInspectorView`

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGInspectorView.swift`

**Interfaces:**
- Consumes: `WYSIWYGInspectorModel` (Task 6), `WYSIWYGPropDescriptor`/`WYSIWYGPropEditorKind` (Task 4), `CSSColor` (`Sources/AnglesiteCore/CSSColor.swift`, existing).
- Produces: `WYSIWYGInspectorView: View`.

Kind→control switch mirroring `TypedEntryEditorView.control(for:)` (`TypedEntryEditorView.swift:44-79`) — exhaustive, no `default:`, so a new `WYSIWYGPropEditorKind` case fails to compile here instead of silently falling through. The `.color` case reuses `CSSColor.parse`/`.format` exactly as `ComponentStyleInspectorPane.swift:171-187` does for its own ColorPicker-over-hex-text pattern.

This task has no dedicated test file — SwiftUI view bodies in this codebase aren't unit-tested (no existing precedent for it: `PageInspectorView`, `ComponentStyleInspectorPane`, `TypedEntryEditorView` have none either); Task 6's model tests cover the logic this view reads from, and Task 8's manual verification step covers the rendered result.

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGInspectorView.swift
import SwiftUI
import AnglesiteCore

/// The native inspector pane for a selected WYSIWYG block's typed props (#1588 Task 7, design doc
/// §4: "system controls: steppers, color wells with the system color panel, pop-up buttons").
struct WYSIWYGInspectorView: View {
    @Bindable var model: WYSIWYGInspectorModel

    var body: some View {
        Form {
            if model.descriptors.isEmpty {
                ContentUnavailableView("No editable properties", systemImage: "slider.horizontal.3")
            } else {
                ForEach(model.descriptors, id: \.name) { descriptor in
                    control(for: descriptor)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func control(for descriptor: WYSIWYGPropDescriptor) -> some View {
        switch descriptor.kind {
        case .text:
            TextField(descriptor.label, text: Binding(
                get: { model.stringValue(for: descriptor.name) },
                set: { model.setString($0, for: descriptor.name) }))
        case .number:
            Stepper(
                "\(descriptor.label): \(Int(model.numberValue(for: descriptor.name)))",
                value: Binding(
                    get: { model.numberValue(for: descriptor.name) },
                    set: { model.setNumber($0, for: descriptor.name) }))
        case .boolean:
            Toggle(descriptor.label, isOn: Binding(
                get: { model.boolValue(for: descriptor.name) },
                set: { model.setBool($0, for: descriptor.name) }))
        case .color:
            colorControl(for: descriptor)
        case .enumeration:
            Picker(descriptor.label, selection: Binding(
                get: { model.stringValue(for: descriptor.name) },
                set: { model.setString($0, for: descriptor.name) })
            ) {
                ForEach(descriptor.enumOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        }
    }

    /// Mirrors `ComponentStyleInspectorPane`'s ColorPicker-over-hex-text pattern
    /// (`ComponentStyleInspectorPane.swift:171-187`): the text field always works, and a
    /// `ColorPicker` (system color well) appears alongside it once the current value parses as a
    /// hex color.
    private func colorControl(for descriptor: WYSIWYGPropDescriptor) -> some View {
        let stringBinding = Binding(
            get: { model.stringValue(for: descriptor.name) },
            set: { model.setString($0, for: descriptor.name) })
        return HStack {
            TextField(descriptor.label, text: stringBinding)
            if let color = CSSColor.parse(stringBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { stringBinding.wrappedValue = CSSColor.format($0) }))
                .labelsHidden()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGInspectorView.swift
git commit -m "feat(#1588): add WYSIWYGInspectorView kind-to-control switch"
```

---

### Task 8: Swift — route canvas selection into the window inspector

**Files:**
- Modify: `Sources/AnglesiteApp/InspectorContext.swift`
- Modify: `Sources/AnglesiteApp/SiteInspectorView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`

**Interfaces:**
- Consumes: `WYSIWYGInspectorModel` (Task 6), `WYSIWYGInspectorView` (Task 7), `PreviewModel.wysiwygCanvas`/`WYSIWYGCanvasController.selectedBlockId` (existing).
- Produces: `InspectorSelection.wysiwygBlock(WYSIWYGInspectorModel)` case.

Wires the existing unified-inspector routing (`SiteWindowModel.inspectorSelection`, `InspectorContext.swift:50-55`, `SiteInspectorView.swift:35-48`) to surface `WYSIWYGInspectorView` whenever a WYSIWYG block is selected — the same `.inspector()` panel `PageInspectorView`/`ComponentStyleInspectorPane` already mount into (`SiteWindow.swift:298-307`), no new panel/sheet needed.

- [ ] **Step 1: Add the new case and update the switch (no isolated unit test — this is pure routing over already-tested pieces; Task 6/7's tests cover the model/view, and this task's own manual-verification step in Task 20 covers the wiring end to end)**

```swift
// Sources/AnglesiteApp/InspectorContext.swift — extend InspectorSelection
@MainActor
enum InspectorSelection {
    case page(InspectorContext)
    case component(ComponentEditorModel)
    case collection(CollectionInspection)
    /// A selected WYSIWYG block (#1588 Task 8) — surfaces only while the preview pane shows the
    /// canvas in edit mode and a block is selected; see `SiteWindowModel.inspectorSelection`.
    case wysiwygBlock(WYSIWYGInspectorModel)
}
```

```swift
// Sources/AnglesiteApp/SiteInspectorView.swift — extend the (selection, tab) switch
@ViewBuilder private var content: some View {
    switch (selection, tab) {
    case (.page(let context), .metadata):
        PageInspectorView(context: context)
    case (.component(let model), .metadata):
        ComponentMetadataInspectorPane(model: model)
    case (.component(let model), .style):
        ComponentStyleInspectorPane(model: model, webView: canvasWebView)
    case (.wysiwygBlock(let model), .metadata):
        WYSIWYGInspectorView(model: model)
    case (.collection(let inspection), .metadata):
        CollectionInspectorForm(inspection: inspection, previewBaseURL: previewBaseURL)
    case (.page, .style), (.collection, .style), (.wysiwygBlock, .style):
        // Element-level styling needs an element selection, which only the component canvas
        // provides today; preview-page/WYSIWYG element-level styling is a future-phase design
        // (spec §4) — same reasoning that already applies to .page/.collection here.
        ContentUnavailableView(
            "Select something on the page", systemImage: "cursorarrow.rays")
    }
}
```

```swift
// Sources/AnglesiteApp/SiteWindowModel.swift — extend inspectorSelection
var inspectorSelection: InspectorSelection? {
    if case .editor(let file) = mainPaneMode, let componentEditor,
       componentEditor.file.id == file.id {
        return .component(componentEditor)
    }
    if case .preview = mainPaneMode, let canvas = preview.wysiwygCanvas, let selectedBlockId = canvas.selectedBlockId {
        return .wysiwygBlock(WYSIWYGInspectorModel(controller: canvas, blockId: selectedBlockId))
    }
    if case .preview = mainPaneMode, let collectionInspection {
        return .collection(collectionInspection)
    }
    if let inspectorContext { return .page(inspectorContext) }
    return nil
}
```

`WYSIWYGInspectorModel` is intentionally rebuilt fresh on every read here rather than cached like `componentEditor` — it holds no independent draft state (unlike `TypedEntryEditorModel`'s buffered `numberDrafts`), every accessor derives straight from `controller.model`, so a fresh instance per access is harmless and keeps this in line with `.collection`'s/`.page`'s existing simplicity rather than adding a stored-property cache for no behavioral gain.

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/InspectorContext.swift Sources/AnglesiteApp/SiteInspectorView.swift Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(#1588): route WYSIWYG block selection into the window inspector"
```

---

### Task 9: Swift — `WYSIWYGPaletteView` native source list

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGPaletteView.swift`

**Interfaces:**
- Consumes: `WYSIWYGBlockPaletteEntry` (Task 5), `WYSIWYGCanvasController.insertBlock(_:)` (existing, PR1).
- Produces: `WYSIWYGPaletteDragPayload: Codable, Transferable`; `WYSIWYGPaletteView: View`.

Design doc §4: "Native palette as a source list, dragged *from* into the canvas." `InsertCommands`'s menu-only palette (`InsertCommands.swift:149-156`) stays as-is (menus and a palette panel are complementary, not either/or) — this is the new panel, whose rows are also draggable for Task 11's cross-boundary drop.

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGPaletteView.swift
import SwiftUI
import UniformTypeIdentifiers
import AnglesiteCore

extension UTType {
    /// App-internal only (no Info.plist export needed) — this payload never leaves the app's own
    /// drag sessions, so a dynamic UTType is sufficient, same posture `ComponentOutline.swift`'s
    /// `OutlineDragPayload` Transferable already takes for the Component Editor's own in-app drags.
    static let wysiwygBlockPaletteEntry = UTType(exportedAs: "io.dwk.anglesite.wysiwyg-block-palette-entry")
}

/// What a palette row exports when dragged into the canvas (Task 11 reads this on drop) — just
/// enough to build a fresh `BlockNodeContent`, not the whole `WYSIWYGBlockPaletteEntry` (whose
/// `id`/`props` schema the drop target doesn't need to carry across the drag).
struct WYSIWYGPaletteDragPayload: Codable, Transferable {
    let kind: BlockKind
    let componentName: String
    let displayName: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wysiwygBlockPaletteEntry)
    }
}

/// The native block palette (#1588 Task 9, design doc §4: "native source list"). Double-clicking a
/// row inserts at the page root (same as `InsertCommands`'s menu items); dragging a row into the
/// canvas is wired in Task 11.
struct WYSIWYGPaletteView: View {
    let entries: [WYSIWYGBlockPaletteEntry]
    let onInsert: (WYSIWYGBlockPaletteEntry) -> Void

    var body: some View {
        List(entries) { entry in
            Label(entry.displayName, systemImage: Self.icon(for: entry.kind))
                .draggable(WYSIWYGPaletteDragPayload(kind: entry.kind, componentName: entry.componentName, displayName: entry.displayName))
                .onTapGesture(count: 2) { onInsert(entry) }
        }
        .listStyle(.sidebar)
    }

    private static func icon(for kind: BlockKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .astro: "square.on.square"
        case .customElement: "puzzlepiece"
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGPaletteView.swift
git commit -m "feat(#1588): add native WYSIWYGPaletteView source list"
```

---

### Task 10: JS — selection-handle drag chrome, `DragReorderController` wiring, `dropTargetAt`

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/mount.ts`
- Test: `JS/wysiwyg-engine/test/host/mount-drag.test.ts`

**Interfaces:**
- Consumes: `DragReorderController`, `computeDropTarget`, `DropTarget` (`../drag-drop.js`, existing, currently only exercised by e2e fixtures); `computeHandleRect` (`../selection.js`, existing).
- Produces: (module-internal, exported via `__testables`) `renderSelectionHandle(engine, dragReorder): () => void`; `window.__anglesiteWysiwygMount.dropTargetAt(x, y): DropTarget`.

Fixes design doc limitation (b) for the single-document case this slice actually mounts (multi-frame breakpoint support stays deferred — see Global Constraints): wires the existing, previously-unwired `DragReorderController` (`drag-drop.ts:82-166`, "currently instantiated only in the Playwright e2e fixture harness" per research) into the real mount path, driven by a small drag-handle element positioned over the selected block via `computeHandleRect`. Also exposes `dropTargetAt` so Task 11's native drop handler can compute an insertion index without a new bridge message type — same "native pulls via `evaluateJavaScript`" pattern `ComponentEditorCanvasPane.performCanvasDrop` already uses for `window.anglesiteCanvas?.dropTargetAt?.(x, y)`.

- [ ] **Step 1: Write the failing test**

```typescript
// JS/wysiwyg-engine/test/host/mount-drag.test.ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { WysiwygEngine } from "../../src/engine.js";
import type { BlockModel, HostTransport, OpResult } from "../../src/types.js";
import { __testables } from "../../src/host/mount.js";

function stubTransport(): HostTransport {
  return { sendOp: async (): Promise<OpResult> => ({ status: "applied", model: emptyModel() }), onModelUpdate: () => () => {} };
}
function emptyModel(): BlockModel {
  return { path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: {} };
}

describe("mount.ts drag chrome", () => {
  beforeEach(() => { document.body.innerHTML = ""; });

  it("renderSelectionHandle appends a handle element hidden until a block is selected", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle");
    expect(handle).not.toBeNull();
    expect(handle?.style.display).toBe("none");
    dispose();
  });

  it("pointerdown on the handle starts a drag of the currently selected block", () => {
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", "b1");
    document.body.appendChild(el);
    Object.defineProperty(el, "getBoundingClientRect", { value: () => ({ x: 5, y: 5, width: 10, height: 10, top: 5, left: 5, right: 15, bottom: 15 }) });

    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    engine.selection.select("b1");
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);

    const handle = document.getElementById("__anglesite-wysiwyg-drag-handle")!;
    handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
    expect(dragReorder.startDrag).toHaveBeenCalledWith("b1");
    dispose();
  });

  it("dispose removes the handle element", () => {
    const engine = new WysiwygEngine(emptyModel(), stubTransport());
    const dragReorder = { startDrag: vi.fn() } as any;
    const dispose = __testables.renderSelectionHandle(engine, dragReorder);
    dispose();
    expect(document.getElementById("__anglesite-wysiwyg-drag-handle")).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd JS/wysiwyg-engine && npm test -- mount-drag`
Expected: FAIL — `renderSelectionHandle` not in `__testables` yet.

- [ ] **Step 3: Implement**

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — add imports
import { DragReorderController, computeDropTarget } from "../drag-drop.js";
import { computeHandleRect } from "../selection.js";
import type { BlockId } from "../types.js";
```

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — add near wireSelection
/**
 * A small drag-handle element positioned over the selected block (via `computeHandleRect`),
 * dragging which starts an in-canvas reorder through `DragReorderController` (design doc §4/§5,
 * fixing "DragReorderController is currently one-per-document" for the single-document case this
 * slice mounts — see the plan's Global Constraints for why multi-frame support stays deferred).
 * A dedicated handle, not a raw pointerdown-anywhere-on-the-block listener, so dragging doesn't
 * fight with `RichTextEditor`'s own mouse handling for placing a text cursor/selecting text
 * inside an actively-edited block.
 */
function renderSelectionHandle(engine: WysiwygEngine, dragReorder: Pick<DragReorderController, "startDrag">): () => void {
  const handle = document.createElement("div");
  handle.id = "__anglesite-wysiwyg-drag-handle";
  handle.setAttribute(
    "style",
    "position: fixed; width: 14px; height: 14px; margin-left: -18px; cursor: grab; z-index: 2147483647; display: none; background: transparent;",
  );
  document.body.appendChild(handle);

  const reposition = (blockId: BlockId | null) => {
    if (!blockId) {
      handle.style.display = "none";
      return;
    }
    const rect = computeHandleRect(blockId);
    if (!rect) {
      handle.style.display = "none";
      return;
    }
    handle.style.display = "block";
    handle.style.left = `${rect.x}px`;
    handle.style.top = `${rect.y}px`;
  };

  const onPointerDown = (event: PointerEvent) => {
    const blockId = engine.selection.current;
    if (!blockId) return;
    event.preventDefault();
    dragReorder.startDrag(blockId);
  };
  handle.addEventListener("pointerdown", onPointerDown);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type === "selection-changed") reposition(event.blockId);
  });
  reposition(engine.selection.current);

  return () => {
    handle.removeEventListener("pointerdown", onPointerDown);
    unsubscribe();
    handle.remove();
  };
}

export const __testables = { wireSelection, renderSelectionHandle };
```

Wire it into `mount()`/`disposeMounted()` alongside `disposeSelection`, and add `dropTargetAt` to the exposed mount object:

```typescript
// JS/wysiwyg-engine/src/host/mount.ts — extend the Window interface, disposers, and mount()
declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygMount?: {
      mount: (initialModel: BlockModel) => WysiwygEngine;
      unmount: () => void;
      dropTargetAt: (x: number, y: number) => { parentId: string; slot: string; index: number };
    };
  }
}

let disposeSelection: (() => void) | null = null;
let disposeHandle: (() => void) | null = null;

function disposeMounted(): void {
  disposeSelection?.();
  disposeSelection = null;
  disposeHandle?.();
  disposeHandle = null;
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    disposeSelection = wireSelection(engine);
    const dragReorder = new DragReorderController(engine, () => {}, document);
    disposeHandle = renderSelectionHandle(engine, dragReorder);
    return engine;
  },
  unmount(): void {
    disposeMounted();
  },
  dropTargetAt(x: number, y: number) {
    return computeDropTarget({ x, y }, document.body);
  },
};
```

- [ ] **Step 4: Run the tests, typecheck, lint**

Run: `cd JS/wysiwyg-engine && npm test -- mount-drag && npm run typecheck && npm run lint`
Expected: PASS, no errors.

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/mount-drag.test.ts
git commit -m "feat(#1588): wire DragReorderController and expose dropTargetAt"
```

---

### Task 11: Swift — palette cross-boundary drop → `insertBlock`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteApp/PreviewView.swift`

**Interfaces:**
- Consumes: `WYSIWYGPaletteDragPayload` (Task 9), `window.__anglesiteWysiwygMount.dropTargetAt` (Task 10), `WYSIWYGCanvasController.submit(_:)` (existing).
- Produces: a `.dropDestination(for: WYSIWYGPaletteDragPayload.self)` modifier wherever `PreviewView` is embedded for the WYSIWYG canvas, active only while edit mode is on.

Mirrors `ComponentEditorCanvasPane.performCanvasDrop`'s pattern (`ComponentEditorCanvasPane.swift:104-115`): SwiftUI hands over a drop location, native pulls the structural target from JS via `evaluateJavaScript`, then submits the op — no new bridge message type needed for this direction.

- [ ] **Step 1: Add a `WKWebView`-reaching drop handler to `PreviewView`**

```swift
// Sources/AnglesiteApp/PreviewView.swift — add near the other WYSIWYG-specific plumbing
struct WYSIWYGDropTargetPayload: Decodable {
    let parentId: String
    let slot: String
    let index: Int
}

/// Resolves a palette drop's screen location to a structural insertion target via the mounted
/// engine's `dropTargetAt` (Task 10), then submits the resulting `insertBlock` — the WYSIWYG
/// analog of `ComponentEditorCanvasPane.performCanvasDrop`.
@MainActor
func performWYSIWYGPaletteDrop(payload: WYSIWYGPaletteDragPayload, location: CGPoint, webView: WKWebView, controller: WYSIWYGCanvasController) async {
    let script = "JSON.stringify(window.__anglesiteWysiwygMount?.dropTargetAt?.(\(location.x), \(location.y)) ?? null)"
    guard let json = try? await webView.evaluateJavaScript(script) as? String,
          let data = json.data(using: .utf8),
          let target = try? JSONDecoder().decode(WYSIWYGDropTargetPayload.self, from: data)
    else { return }
    let newId = UUID().uuidString
    let content = BlockNodeContent(kind: payload.kind, componentName: payload.componentName, props: [:], slots: [:], sourceSpan: [0, 0])
    await controller.submit(.insertBlock(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content))
}
```

- [ ] **Step 2: Attach `.dropDestination` where the WYSIWYG canvas is hosted**

Find the call site in `Sources/AnglesiteApp/SiteWindow.swift` where `PreviewView(...)` is instantiated for the `.preview` pane (`previewPane(for:)` per the file's existing structure) and add:

```swift
// Sources/AnglesiteApp/SiteWindow.swift — inside previewPane(for:), wrapping the existing PreviewView
PreviewView(/* existing arguments unchanged */)
    .dropDestination(for: WYSIWYGPaletteDragPayload.self) { payloads, location in
        guard let payload = payloads.first, let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView else { return false }
        Task { await performWYSIWYGPaletteDrop(payload: payload, location: location, webView: webView, controller: canvas) }
        return true
    }
```

(`model.preview.webView` — confirm the exact existing accessor name on `PreviewModel` at this call site before editing; `PreviewModel` already exposes a weak `webView` reference used elsewhere for the same purpose, e.g. `PreviewNavigationCommands`. Match whatever that accessor is called rather than introducing a second one.)

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test**

Launch the app (`docs/testing-macos-app.md`), open a site, toggle Site ▸ Edit Page, open the block palette (Task 20 wires its toolbar toggle — until then it can be previewed by temporarily embedding `WYSIWYGPaletteView` directly), drag a palette row onto the canvas, and confirm a new block appears at the drop point. Record the result in this task's commit message or the eventual PR body.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PreviewView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1588): submit insertBlock for a palette drop onto the canvas"
```

---

### Task 12: Swift — `WYSIWYGImageAssetIngestor`

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGImageAssetIngestorTests.swift`

**Interfaces:**
- Produces: `WYSIWYGImageAssetIngestor.ingest(bytes:siteDirectory:fileManager:) throws -> String?`.

A fresh, generic type rather than reusing `LinkImageAsset.install` (`Sources/AnglesiteCore/LinkImageAsset.swift`) — that type's identity model is keyed to a link-post's `slug` (one image per captured link, overwritten on re-capture), which doesn't fit an arbitrary in-canvas image drop with no slug. The magic-byte sniffing approach is intentionally the same shape as that precedent (`LinkImageAsset.format(sniffing:)`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGImageAssetIngestor")
struct WYSIWYGImageAssetIngestorTests {
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0])

    @Test("ingests a recognized PNG into public/images and returns its root-relative path")
    func ingestsPNG() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = try WYSIWYGImageAssetIngestor.ingest(bytes: Self.pngBytes, siteDirectory: tempDir)

        #expect(path?.hasPrefix("/images/") == true)
        #expect(path?.hasSuffix(".png") == true)
        let written = tempDir.appendingPathComponent("public/images").appendingPathComponent(String(path!.dropFirst("/images/".count)))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("returns nil for unrecognized bytes instead of writing a file")
    func returnsNilForUnrecognizedFormat() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = try WYSIWYGImageAssetIngestor.ingest(bytes: Data([0x00, 0x01, 0x02]), siteDirectory: tempDir)

        #expect(path == nil)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("public/images").path))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGImageAssetIngestorTests`
Expected: FAIL — type doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift
import Foundation

/// Writes a Finder/Photos-dragged image's raw bytes into the site's `public/images/` (design doc
/// §4: "Finder/Photos drag-in → asset ingestion + image block in one gesture"), returning the
/// root-relative URL path an inserted image block's `src` prop should use. Sniffs the format from
/// magic bytes rather than trusting a claimed extension/UTI — same reasoning and byte-signature
/// table as `LinkImageAsset.format(sniffing:)`, which this type deliberately doesn't reuse (that
/// type's `install` is keyed to a link-post `slug` identity that doesn't fit an arbitrary canvas
/// drop).
public enum WYSIWYGImageAssetIngestor {
    enum Format: String {
        case jpeg, png, gif, webp

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .gif: "gif"
            case .webp: "webp"
            }
        }
    }

    /// Returns `nil` for unrecognized bytes — callers treat that as "not a droppable image,
    /// ignore the drop" rather than a thrown error.
    /// - Throws: whatever `FileManager`/`Data.write` throws for a recognized image that fails to
    ///   write.
    public static func ingest(bytes: Data, siteDirectory: URL, fileManager: FileManager = .default) throws -> String? {
        guard let format = sniff(bytes) else { return nil }
        let directory = siteDirectory.appendingPathComponent("public/images", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "wysiwyg-\(UUID().uuidString.prefix(8)).\(format.fileExtension)"
        let destination = directory.appendingPathComponent(name)
        try bytes.write(to: destination, options: .atomic)
        return "/images/\(name)"
    }

    private static func sniff(_ data: Data) -> Format? {
        func matches(_ signature: [UInt8], at offset: Int) -> Bool {
            guard data.count >= offset + signature.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: signature.count)]) == signature
        }
        if matches([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        if matches(Array("GIF8".utf8), at: 0) { return .gif }
        if matches(Array("RIFF".utf8), at: 0), matches(Array("WEBP".utf8), at: 8) { return .webp }
        return nil
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGImageAssetIngestorTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift Tests/AnglesiteCoreTests/WYSIWYGImageAssetIngestorTests.swift
git commit -m "feat(#1588): add WYSIWYGImageAssetIngestor for dragged-image bytes"
```

---

### Task 13: Swift — Finder/Photos drag-in wiring

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGImageDropHandler.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGImageDropHandlerTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGImageAssetIngestor.ingest` (Task 12), `WYSIWYGCanvasController.submit(_:)`, `PreviewModel.openSiteDirectory` (existing).
- Produces: `WYSIWYGImageDropHandler.loadImageBytes(from:) async -> Data?`.

Reads raw image bytes from an `NSItemProvider` — the type Finder and Photos both hand SwiftUI's drop APIs for a native drag — trying `public.image` first (Photos, and Finder for files whose UTI conforms to image), falling back to `public.file-url` (a plain file drag) read via `Data(contentsOf:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import AnglesiteAppCore

@Suite("WYSIWYGImageDropHandler")
struct WYSIWYGImageDropHandlerTests {
    @Test("loads bytes directly from a provider offering public.image data")
    func loadsFromImageData() async {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider(item: bytes as NSSecureCoding, typeIdentifier: UTType.png.identifier)

        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [provider])

        #expect(loaded == bytes)
    }

    @Test("returns nil when the provider offers neither image data nor a file URL")
    func returnsNilForUnsupportedProvider() async {
        let provider = NSItemProvider(item: "not an image" as NSSecureCoding, typeIdentifier: UTType.plainText.identifier)

        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [provider])

        #expect(loaded == nil)
    }

    @Test("returns nil for an empty provider list")
    func returnsNilForEmptyProviders() async {
        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [])
        #expect(loaded == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGImageDropHandlerTests`
Expected: FAIL — type doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGImageDropHandler.swift
import Foundation
import UniformTypeIdentifiers

/// Reads raw image bytes from a Finder/Photos drag's `NSItemProvider`s (#1588 Task 13, design
/// doc §4: "Finder/Photos drag-in → asset ingestion"). Tries `public.image` first (what Photos
/// hands over, and what Finder offers for files whose UTI conforms to image), then falls back to
/// `public.file-url` (a plain file drag) read straight off disk.
@MainActor
enum WYSIWYGImageDropHandler {
    static func loadImageBytes(from providers: [NSItemProvider]) async -> Data? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await loadDataRepresentation(provider, typeIdentifier: UTType.image.identifier) {
            return data
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let urlData = try? await loadDataRepresentation(provider, typeIdentifier: UTType.fileURL.identifier),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let fileData = try? Data(contentsOf: url) {
            return fileData
        }
        return nil
    }

    private static func loadDataRepresentation(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
```

Wire it onto the canvas alongside Task 11's `.dropDestination`, in the same `SiteWindow.swift` call site:

```swift
// Sources/AnglesiteApp/SiteWindow.swift — stacked alongside the .dropDestination from Task 11
.onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers, location in
    guard let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView,
          let siteDirectory = model.preview.openSiteDirectory
    else { return false }
    Task {
        guard let bytes = await WYSIWYGImageDropHandler.loadImageBytes(from: providers),
              let assetPath = try? WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: siteDirectory)
        else { return }
        let script = "JSON.stringify(window.__anglesiteWysiwygMount?.dropTargetAt?.(\(location.x), \(location.y)) ?? null)"
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let target = try? JSONDecoder().decode(WYSIWYGDropTargetPayload.self, from: data)
        else { return }
        let newId = UUID().uuidString
        // Alt-text proposal is stubbed empty — the real proposal is on-device AI (#1227, out of
        // scope here per the design doc).
        let content = BlockNodeContent(
            kind: .astro, componentName: "img", props: ["src": .string(assetPath), "alt": .string("")],
            slots: [:], sourceSpan: [0, 0])
        await canvas.submit(.insertBlock(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content))
    }
    return true
}
```

- [ ] **Step 4: Run the test, build**

Run: `swift test --filter WYSIWYGImageDropHandlerTests && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS; BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke test**

Drag an image from Finder onto the canvas in edit mode; confirm an image block appears with `src` pointing at the newly written `public/images/` file.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGImageDropHandler.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteAppTests/WYSIWYGImageDropHandlerTests.swift
git commit -m "feat(#1588): ingest Finder/Photos image drops into an image block"
```

---

### Task 14: Swift — `WYSIWYGRichTextPasteMapper`

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGRichTextPasteMapper.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGRichTextPasteMapperTests.swift`

**Interfaces:**
- Consumes: `RichTextRun` (`WYSIWYGOps.swift`, existing).
- Produces: `WYSIWYGRichTextPasteMapper.map(_:plainTextOnly:) -> [[RichTextRun]]` (one `[RichTextRun]` per paragraph).

Design doc §8.4: "rich text from Pages/Word/Safari maps to blocks and honest inline runs." `AppKit`-gated (`#if canImport(AppKit)`), matching `CSSColor.swift`'s pattern for `AnglesiteCore`'s Linux portability.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
#if canImport(AppKit)
import AppKit
@testable import AnglesiteCore

@Suite("WYSIWYGRichTextPasteMapper")
struct WYSIWYGRichTextPasteMapperTests {
    @Test("splits multiple paragraphs into separate run lists")
    func splitsParagraphs() {
        let attributed = NSAttributedString(string: "First\nSecond")
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].first?.text == "First")
        #expect(paragraphs[1].first?.text == "Second")
    }

    @Test("maps a bold run to strong and a plain run to text")
    func mapsBoldRun() {
        let attributed = NSMutableAttributedString(string: "bold plain")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 0, length: 4))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs[0].contains { $0.kind == .strong && $0.text == "bold" })
        #expect(paragraphs[0].contains { $0.kind == .text && $0.text == " plain" })
    }

    @Test("maps a link attribute to a link run carrying href")
    func mapsLinkRun() {
        let attributed = NSMutableAttributedString(string: "click here")
        attributed.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 10))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs[0].first?.kind == .link)
        #expect(paragraphs[0].first?.href == "https://example.com")
    }

    @Test("plainTextOnly collapses every run to plain text runs (Paste and Match Style)")
    func plainTextOnlyCollapsesFormatting() {
        let attributed = NSMutableAttributedString(string: "bold")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 0, length: 4))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed, plainTextOnly: true)
        #expect(paragraphs[0] == [RichTextRun(kind: .text, text: "bold")])
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGRichTextPasteMapperTests`
Expected: FAIL — type doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGRichTextPasteMapper.swift
// SwiftUI/AppKit-only: NSAttributedString/NSFont aren't available on the portable core's Linux
// build (cross-platform port design §5) — same posture as CSSColor.swift.
#if canImport(AppKit)
import AppKit
import Foundation

/// Maps a pasted `NSAttributedString` (RTF/HTML from Pages/Word/Safari) into paragraph-level
/// `RichTextRun` lists — the shape `insertBlock` ops build text blocks from (design doc §8.4:
/// "rich text... maps to blocks and honest inline runs"). `plainTextOnly` collapses every run to
/// `.text`, for ⇧⌥⌘V "Paste and Match Style" — only the text content survives, no formatting.
public enum WYSIWYGRichTextPasteMapper {
    public static func map(_ attributed: NSAttributedString, plainTextOnly: Bool = false) -> [[RichTextRun]] {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        var result: [[RichTextRun]] = []
        var location = 0
        for paragraph in paragraphs {
            let length = (paragraph as NSString).length
            defer { location += length + 1 } // +1 accounts for the removed "\n"
            guard length > 0 else {
                result.append([])
                continue
            }
            let range = NSRange(location: location, length: length)
            guard range.location + range.length <= attributed.length else {
                result.append([RichTextRun(kind: .text, text: paragraph)])
                continue
            }
            let slice = attributed.attributedSubstring(from: range)
            result.append(plainTextOnly ? [RichTextRun(kind: .text, text: slice.string)] : runs(for: slice))
        }
        return result
    }

    private static func runs(for attributed: NSAttributedString) -> [RichTextRun] {
        var result: [RichTextRun] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            if let link = attributes[.link] as? URL {
                result.append(RichTextRun(kind: .link, text: text, href: link.absoluteString))
                return
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    result.append(RichTextRun(kind: .strong, text: text))
                    return
                }
                if traits.contains(.italic) {
                    result.append(RichTextRun(kind: .em, text: text))
                    return
                }
            }
            result.append(RichTextRun(kind: .text, text: text))
        }
        return result
    }
}
#endif
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WYSIWYGRichTextPasteMapperTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGRichTextPasteMapper.swift Tests/AnglesiteCoreTests/WYSIWYGRichTextPasteMapperTests.swift
git commit -m "feat(#1588): add WYSIWYGRichTextPasteMapper for semantic paste"
```

---

### Task 15: Swift — Paste / Paste and Match Style menu wiring

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGPasteCommands.swift`

**Interfaces:**
- Consumes: `WYSIWYGRichTextPasteMapper.map` (Task 14), `EditorFocusRegistry.shared` (existing, `.wysiwygCanvas` case), `WYSIWYGCanvasController.submit(_:)`.
- Produces: `WYSIWYGPasteCommands: Commands` (⌘V / ⇧⌥⌘V, active only when the WYSIWYG canvas holds `EditorFocusRegistry` focus).

Follows `FormatCommands`'s exact dispatch pattern (`FormatCommands.swift:22-25`: `if case .wysiwygCanvas(let box) = registry.active { box.value }`) rather than `@FocusedValue` — this is genuinely "paste onto the canvas, inserting new blocks," not paste-into-an-actively-edited-text-run (which stays whatever `RichTextEditor`'s own contentEditable paste already does, unaffected by this task).

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGPasteCommands.swift
import SwiftUI
import AppKit
import AnglesiteCore

/// Edit ▸ Paste / Paste and Match Style for the WYSIWYG canvas (#1588 Task 15, design doc §8.4).
/// Follows `FormatCommands`'s `EditorFocusRegistry`-based dispatch (not `@FocusedValue`) since
/// both need the same "which editor currently owns keyboard focus" answer.
struct WYSIWYGPasteCommands: Commands {
    @ObservedObject private var registry = EditorFocusRegistry.shared

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Paste and Match Style") {
                paste(matchStyle: true)
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            .disabled(wysiwygController == nil)
        }
    }

    private var wysiwygController: WYSIWYGCanvasController? {
        guard case .wysiwygCanvas(let box) = registry.active else { return nil }
        return box.value
    }

    private func paste(matchStyle: Bool) {
        guard let controller = wysiwygController else { return }
        let pasteboard = NSPasteboard.general
        let attributed: NSAttributedString?
        if let rtfData = pasteboard.data(forType: .rtf) {
            attributed = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        } else if let htmlData = pasteboard.data(forType: .html) {
            attributed = try? NSAttributedString(data: htmlData, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        } else if let plain = pasteboard.string(forType: .string) {
            attributed = NSAttributedString(string: plain)
        } else {
            attributed = nil
        }
        guard let attributed else { return }
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed, plainTextOnly: matchStyle)
        Task {
            for runs in paragraphs where !runs.isEmpty {
                let newId = UUID().uuidString
                let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: runs)
                await controller.submit(.insertBlock(parentId: rootParentID, slot: "main", index: controller.model.rootIds.count, newId: newId, block: content))
            }
        }
    }
}
```

`EditorFocusRegistry` is `@MainActor @Observable` (per `FocusedSite.swift`'s doc comment on `.wysiwygCanvas`), and this file reads it via `@ObservedObject`-style access to stay consistent with how `FormatCommands.swift` already reads `registry.active` — check that file's exact property-wrapper usage before finalizing this one so both use the same convention rather than introducing a second.

The plain ⌘V "Paste" (not Match Style) is deliberately **not** added here — the standard system Edit ▸ Paste item already exists and today routes into whatever `RichTextEditor`'s contentEditable paste handling does; this task only adds the new ⇧⌥⌘V command, which has no system default to conflict with.

- [ ] **Step 2: Register the new Commands group**

Find where `FormatCommands`/`NavigatorEditCommands` are added to the app's `Commands` (`AnglesiteApp.swift`'s `.commands { ... }` block) and add `WYSIWYGPasteCommands()` alongside them.

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test**

Copy styled text from Pages/Safari, toggle Site ▸ Edit Page, give the canvas keyboard focus, press ⇧⌥⌘V, and confirm one new paragraph block per copied paragraph with bold/italic/link runs preserved as plain text (Match Style).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGPasteCommands.swift
git commit -m "feat(#1588): wire semantic Paste and Match Style for the WYSIWYG canvas"
```

---

### Task 16: Swift — block copy puts HTML + plain text on the pasteboard

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockClipboardWriter.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGPasteCommands.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGBlockClipboardWriterTests.swift`

**Interfaces:**
- Produces: `WYSIWYGBlockClipboardWriter.render(_:) -> (html: String, plainText: String)`; `WYSIWYGCanvasController.copySelectedBlock(pasteboard:)`.

Design doc §8.4: "copying a block puts real HTML + plain text on the pasteboard."

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGBlockClipboardWriter")
struct WYSIWYGBlockClipboardWriterTests {
    @Test("renders rich text runs to matching HTML tags and plain text")
    func rendersRichTextRuns() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "Hello "), RichTextRun(kind: .strong, text: "world")])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>Hello <strong>world</strong></p>")
        #expect(plain == "Hello world")
    }

    @Test("falls back to componentName for a block with no rich text")
    func fallsBackForNonTextBlock() {
        let node = BlockNode(id: "b1", kind: .astro, componentName: "Callout", props: [:], slots: [:], sourceSpan: [0, 0])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<div>Callout</div>")
        #expect(plain == "Callout")
    }

    @Test("escapes HTML-significant characters in run text")
    func escapesHTML() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "<script>")])

        let (html, _) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>&lt;script&gt;</p>")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WYSIWYGBlockClipboardWriterTests`
Expected: FAIL — type doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockClipboardWriter.swift
import Foundation

/// Renders a `BlockNode` to minimal semantic HTML plus its plain-text equivalent — design doc
/// §8.4: "copying a block puts real HTML + plain text on the pasteboard." A block with no rich
/// text (e.g. a bare `Callout`) falls back to its `componentName` for both, so copying never
/// produces empty pasteboard content.
public enum WYSIWYGBlockClipboardWriter {
    public static func render(_ node: BlockNode) -> (html: String, plainText: String) {
        guard let runs = node.richText, !runs.isEmpty else {
            return ("<div>\(escapeHTML(node.componentName))</div>", node.componentName)
        }
        return ("<p>\(runs.map(runHTML).joined())</p>", runs.map(\.text).joined())
    }

    private static func runHTML(_ run: RichTextRun) -> String {
        let text = escapeHTML(run.text)
        switch run.kind {
        case .text: return text
        case .strong: return "<strong>\(text)</strong>"
        case .em: return "<em>\(text)</em>"
        case .code: return "<code>\(text)</code>"
        case .link: return "<a href=\"\(escapeHTML(run.href ?? ""))\">\(text)</a>"
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

Add the pasteboard-writing method to `WYSIWYGCanvasController`:

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — add near duplicateSelectedBlock/deleteSelectedBlock
    /// The Edit ▸ Copy target for the canvas's block selection (#1588 Task 16) — writes real HTML
    /// + plain text via `WYSIWYGBlockClipboardWriter`, not just a debug string.
    func copySelectedBlock(pasteboard: NSPasteboard = .general) {
        guard let id = selectedBlockId, let node = model.blocks[id] else { return }
        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)
        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
        if let htmlData = html.data(using: .utf8) {
            pasteboard.setData(htmlData, forType: .html)
        }
    }
```

Wire ⌘C into the same `WYSIWYGPasteCommands` group from Task 15 (renaming the file's intent slightly — copy and paste share the same focus-dispatch pattern):

```swift
// Sources/AnglesiteApp/WYSIWYGPasteCommands.swift — add inside the CommandGroup(after: .pasteboard) body
Button("Copy") {
    wysiwygController?.copySelectedBlock()
}
.keyboardShortcut("c", modifiers: [.command])
.disabled(wysiwygController?.selectedBlockId == nil)
```

- [ ] **Step 4: Run the test, build**

Run: `swift test --filter WYSIWYGBlockClipboardWriterTests && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS; BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockClipboardWriter.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/WYSIWYGPasteCommands.swift Tests/AnglesiteCoreTests/WYSIWYGBlockClipboardWriterTests.swift
git commit -m "feat(#1588): copy a selected block as real HTML + plain text"
```

---

### Task 17: Swift — edited-dot tied to uncommitted ops

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Create: `Sources/AnglesiteApp/WindowEditedStateBridge.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Produces: `WYSIWYGCanvasController.hasUncommittedOps: Bool`; `WindowEditedStateBridge: NSViewRepresentable`.

Design doc §4: "edited-dot tied to uncommitted ops (against the stub backend until #1222 lands, this reflects uncommitted in-memory ops rather than a real git-dirty state)." No `isDocumentEdited`/`NSDocument` precedent exists anywhere in the app (confirmed by grep) — every other editor here uses an auto-save-on-leave model instead, so this is genuinely new machinery, bridged into `NSWindow.isDocumentEdited` (the titlebar dot) via a minimal `NSViewRepresentable`, the standard SwiftUI-to-AppKit-window escape hatch.

- [ ] **Step 1: Write the failing test**

```swift
// Add to Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
@Test("hasUncommittedOps flips true after a successful submit")
func hasUncommittedOpsFlipsAfterSubmit() async {
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
    #expect(controller.hasUncommittedOps == false)

    _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

    #expect(controller.hasUncommittedOps == true)
}

@Test("hasUncommittedOps stays false when a submit is rejected")
func hasUncommittedOpsStaysFalseOnRejection() async {
    let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
    let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
    controller.forceTargetVersion = "stale"

    _ = await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b"))

    #expect(controller.hasUncommittedOps == false)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `hasUncommittedOps` doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — add a stored property and flip it in submit
    /// Whether any op has applied since this canvas mounted — the interim "uncommitted ops"
    /// signal `WindowEditedStateBridge` (#1588 Task 17) drives the titlebar edited-dot from.
    /// Explicitly *not* a real git-dirty flag: against `StubWYSIWYGHostTransport` every applied op
    /// is only ever in-memory, so this stays true for the rest of the editing session once set —
    /// the design doc flags this as a stand-in until #1222's real backend lands.
    private(set) var hasUncommittedOps = false
```

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — inside submit(_:), after a successful apply
    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let result = await apply(op)
        if case .applied(let newModel) = result {
            hasUncommittedOps = true
            fireOpApplied(op, WYSIWYGOpInverter.invert(op), newModel)
        }
        return result
    }
```

```swift
// Sources/AnglesiteApp/WindowEditedStateBridge.swift
import SwiftUI
import AppKit

/// Bridges `WYSIWYGCanvasController.hasUncommittedOps` into `NSWindow.isDocumentEdited` (#1588
/// Task 17) — the titlebar's edited dot. No existing `NSDocument`/`isDocumentEdited` precedent in
/// this app (every other editor auto-saves on focus-leave instead), so this is the minimal
/// SwiftUI-to-AppKit-window bridge for the one surface that genuinely needs it.
struct WindowEditedStateBridge: NSViewRepresentable {
    var isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = isEdited
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.isDocumentEdited = false
    }
}
```

Mount it in `SiteWindow.swift` near the existing `.navigationDocument`/`.toolbar(id:)` modifiers:

```swift
// Sources/AnglesiteApp/SiteWindow.swift — add alongside .navigationDocument(site.packageURL)
.background(WindowEditedStateBridge(isEdited: model.preview.wysiwygCanvas?.hasUncommittedOps ?? false))
```

- [ ] **Step 4: Run the tests, build**

Run: `swift test --filter WYSIWYGCanvasControllerTests && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS; BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/WindowEditedStateBridge.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1588): drive the titlebar edited-dot from uncommitted canvas ops"
```

---

### Task 18: Swift — per-page document title/proxy icon while editing

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Produces: `PreviewModel.editingPageSourceURL: URL?`, `PreviewModel.editingPageTitle: String?`.

Design doc §4: "window title = page title with the document proxy icon pointing at the real `Source/` file." Today `.navigationTitle(site.name)` and `.navigationDocument(site.packageURL)` (`SiteWindow.swift:308-309`) always show the site's name and point at the whole `.anglesite` package. While WYSIWYG edit mode is active, both should reflect the specific page being edited instead.

- [ ] **Step 1: Add the computed properties**

```swift
// Sources/AnglesiteApp/PreviewModel.swift — add near wysiwygCanvas/isEditModeEnabled
    /// The `Source/`-relative page file currently mounted in the WYSIWYG canvas, resolved against
    /// `openSiteDirectory` — `nil` outside edit mode, or before a site directory is known.
    /// `.navigationDocument` uses this (Task 18) so the window's proxy icon points at the specific
    /// page being edited rather than the whole package.
    var editingPageSourceURL: URL? {
        guard let canvas = wysiwygCanvas, let openSiteDirectory else { return nil }
        return openSiteDirectory.appendingPathComponent(canvas.model.path)
    }

    /// The edited page's own title while WYSIWYG edit mode is active — the last path component of
    /// `editingPageSourceURL` with its extension stripped, as a readable stand-in until a real
    /// page-title field exists on `BlockModel` (out of scope here; `BlockModel.path` is the only
    /// per-page identifier PR1 gave the model). `nil` outside edit mode, so `SiteWindow` falls
    /// back to the site's own name.
    var editingPageTitle: String? {
        guard let url = editingPageSourceURL else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
```

- [ ] **Step 2: Wire both into `SiteWindow`'s title/proxy icon**

```swift
// Sources/AnglesiteApp/SiteWindow.swift — replace the existing .navigationTitle/.navigationDocument lines
.navigationTitle(model.preview.editingPageTitle ?? site.name)
.navigationDocument(model.preview.editingPageSourceURL ?? site.packageURL)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test**

Toggle Site ▸ Edit Page on a page; confirm the titlebar text switches to the page's file-derived title, and ⌘-click the title bar to confirm the shown path is the specific page's `.astro` file inside `Source/`, not the `.anglesite` package. Toggle edit mode off and confirm both revert to the site's name/package.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1588): show the edited page's title and proxy icon while editing"
```

---

### Task 19: Swift — native find bar for the WYSIWYG canvas

**Files:**
- Create: `Sources/AnglesiteApp/WYSIWYGFindBar.swift`
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Modify: `Sources/AnglesiteApp/EditMenuSkeletonCommands.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Produces: `WYSIWYGCanvasController.isFindBarPresented: Bool`, `find(_:backwards:)`; `WYSIWYGFindBar: View`.

`EditorFocusRegistry.Focus.wysiwygCanvas` already exists as a case (`FocusedSite.swift`'s doc comment, added ahead of this work), but `EditMenuSkeletonCommands`'s `.wysiwygCanvas` arms are confirmed no-op stubs today (`EditMenuSkeletonCommands.swift:63,72,80,84,91,94,98,101` — every `.wysiwygCanvas` case is `break`/`false`). This task implements them using `WKWebView.find(_:configuration:completionHandler:)` (macOS 13.3+, safely available at this app's macOS 27+ floor).

- [ ] **Step 1: Add find state/methods to the controller**

```swift
// Sources/AnglesiteApp/WYSIWYGCanvasController.swift — add near hasKeyboardFocus
    /// Whether the WYSIWYG find bar is showing (#1588 Task 19) — `EditMenuSkeletonCommands`'s
    /// Edit ▸ Find dispatch flips this on; `WYSIWYGFindBar` flips it off.
    var isFindBarPresented = false

    /// Performs a native in-page find via `WKWebView.find` — no custom highlighting/DOM
    /// manipulation needed, WebKit handles scroll-to-match and highlight itself.
    func find(_ query: String, backwards: Bool = false) {
        guard let webView, !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { _ in }
    }
```

- [ ] **Step 2: Wire `EditMenuSkeletonCommands`'s `.wysiwygCanvas` arms**

Read `Sources/AnglesiteApp/EditMenuSkeletonCommands.swift` in full first — it dispatches on `registry.active` with a `case .wysiwygCanvas(let box):`-shaped pattern per `FormatCommands`'s precedent. Replace each `.wysiwygCanvas` `break`/`false` arm:

```swift
// Sources/AnglesiteApp/EditMenuSkeletonCommands.swift — hasFindUI
private var hasFindUI: Bool {
    switch registry.active {
    case .markdown: true
    case .wysiwygCanvas: true
    case .plainText, nil: false
    }
}
```

```swift
// Sources/AnglesiteApp/EditMenuSkeletonCommands.swift — performFind
private func performFind() {
    switch registry.active {
    case .markdown(let box): box.value?.presentFind()
    case .wysiwygCanvas(let box): box.value?.isFindBarPresented = true
    case .plainText, nil: break
    }
}
```

`performFindNext`/`performFindPrevious` route to `box.value?.find(lastQuery, backwards: ...)` — since the controller doesn't retain a "last query" itself, thread it through `WYSIWYGFindBar`'s own `@State` instead: Next/Previous while the bar isn't presented is a no-op (matching `hasFindUI`'s gating — those menu items are only enabled while a find surface exists), and while it is presented, the bar's own onSubmit/button handlers (Step 3) own repeat-find, so `performFindNext`/`performFindPrevious`'s `.wysiwygCanvas` arms stay `break` — same as `.plainText`'s existing arms, which lean on SwiftUI's own `.findNavigator` for repeat-find rather than routing it through this menu dispatch either. Leave `performFindReplace`'s `.wysiwygCanvas` arm as `break` — the WYSIWYG canvas has no text-replace concept (design doc's ⌘F scope is search-only, matching the plain-text surface's own `.findNavigator`, which doesn't support replace either).

- [ ] **Step 3: Build the find bar view**

```swift
// Sources/AnglesiteApp/WYSIWYGFindBar.swift
import SwiftUI

/// The WYSIWYG canvas's native find bar (#1588 Task 19, design doc §4: "native ⌘F find bar").
/// Thin chrome over `WYSIWYGCanvasController.find(_:backwards:)` — WebKit owns match
/// highlighting/scrolling via `WKWebView.find` itself.
struct WYSIWYGFindBar: View {
    @Bindable var controller: WYSIWYGCanvasController
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        if controller.isFindBarPresented {
            HStack {
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { controller.find(query) }
                    .frame(maxWidth: 240)
                Button {
                    controller.find(query, backwards: true)
                } label: {
                    Image(systemName: "chevron.up")
                }
                Button {
                    controller.find(query)
                } label: {
                    Image(systemName: "chevron.down")
                }
                Button("Done") {
                    controller.isFindBarPresented = false
                }
                .keyboardShortcut(.escape)
            }
            .padding(8)
            .background(.bar)
            .onAppear { focused = true }
        }
    }
}
```

Mount it as an overlay near the top of the preview pane in `SiteWindow.swift`, e.g.:

```swift
// Sources/AnglesiteApp/SiteWindow.swift — inside previewPane(for:), overlaying the existing PreviewView stack
.overlay(alignment: .top) {
    if let canvas = model.preview.wysiwygCanvas {
        WYSIWYGFindBar(controller: canvas)
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke test**

Toggle Site ▸ Edit Page, give the canvas focus, press ⌘F, type a word known to be on the page, press Return, and confirm WebKit scrolls to and highlights the match.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGFindBar.swift Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/EditMenuSkeletonCommands.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1588): implement the native find bar for the WYSIWYG canvas"
```

---

### Task 20: Swift — toolbar items for the palette + Customize Toolbar

**Files:**
- Modify: `Sources/AnglesiteCore/SiteToolbarItemID.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Produces: `SiteToolbarItemID.wysiwygPalette` (new case).

The site window's toolbar already adopts `.toolbar(id: "site")` (`SiteWindow.swift:323`), so Customize Toolbar already works for the window generally — design doc §4's ask is specifically that the *new* panels this plan adds get proper toolbar items rather than being reachable only via menu, following the file's own established rules (`SiteWindow.swift:316-322`: stable id, unconditional item, disabled rather than hidden when inactive). The Inspector toggle reuses the existing `SiteToolbarItemID.inspector` case (already wired to the unified inspector `PageInspectorView`/`ComponentStyleInspectorPane`/`WYSIWYGInspectorView` all share via Task 8) — only the palette needs a new id.

- [ ] **Step 1: Add the new case and update the frozen-set test**

```swift
// Sources/AnglesiteCore/SiteToolbarItemID.swift — add inside the enum, near `inspector`
    /// Toggles the native WYSIWYG block palette source list (#1588 Task 20).
    case wysiwygPalette
```

Add `.wysiwygPalette` to whatever exhaustive/count assertion `SiteToolbarItemIDTests` uses to freeze the case set (read that test file first — it may assert `CaseIterable.allCases.count` or list every raw value explicitly; match its existing style rather than guessing the assertion shape).

- [ ] **Step 2: Run the toolbar-id test to verify it fails, then passes**

Run: `swift test --filter SiteToolbarItemIDTests`
Expected: FAIL until the test file is updated to include the new case, then PASS.

- [ ] **Step 3: Add the toolbar item**

```swift
// Sources/AnglesiteApp/SiteWindow.swift — inside .toolbar(id: "site") { ... }, alongside the existing ToolbarItems
ToolbarItem(id: SiteToolbarItemID.wysiwygPalette.rawValue, placement: .primaryAction) {
    Button {
        showWYSIWYGPalette.toggle()
    } label: {
        Label("Block Palette", systemImage: "square.grid.2x2")
    }
    .disabled(!model.preview.isEditModeEnabled)
}
```

This needs a `@State private var showWYSIWYGPalette = false` on `SiteWindow`, and mounting `WYSIWYGPaletteView` (Task 9) as an `.inspector`-adjacent or trailing-sidebar panel gated on it — e.g. a second `.inspector(isPresented: $showWYSIWYGPalette)` is not available (SwiftUI only supports one `.inspector` per scene), so mount it via `.sheet`/a leading `.safeAreaInset` panel instead. Given `SiteWindow.swift` already has an established convention for a secondary panel (the Navigator sidebar), read that file's sidebar-panel wiring first and reuse the same mechanism (most likely a `NavigationSplitView` column or `.safeAreaInset(edge: .leading)`) rather than introducing a third panel-presentation idiom.

```swift
// Sources/AnglesiteApp/SiteWindow.swift — wherever the chosen panel mechanism mounts content
.safeAreaInset(edge: .leading) {
    if showWYSIWYGPalette, model.preview.isEditModeEnabled {
        WYSIWYGPaletteView(entries: WYSIWYGCanvasController.stubBlockPalette) { entry in
            Task { await model.preview.wysiwygCanvas?.insertBlock(entry) }
        }
        .frame(width: 220)
    }
}
```

(Exact modifier/placement should match whatever panel-presentation convention `SiteWindow.swift` already establishes for its Navigator sidebar — inspect that code before finalizing this step rather than introducing a new layout pattern.)

- [ ] **Step 4: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke test — full PR2 pass**

With the app built and a site open:
1. Toggle Site ▸ Edit Page. Confirm the titlebar proxy icon now points at the page file (Task 18) and View ▸ Customize Toolbar shows the new "Block Palette" item (Task 20).
2. Click the palette toolbar item; confirm `WYSIWYGPaletteView` appears (Task 9) with Paragraph/Heading/Callout/Image rows.
3. Click a block in the canvas; confirm the inspector switches to show its typed props (Tasks 1-2, 6-8), and editing a Callout's title/color/emphasis updates the canvas live.
4. Drag a palette row onto the canvas; confirm it inserts at the drop point (Task 11).
5. Select a block and drag its handle to reorder; confirm `moveBlock` applies (Task 10).
6. Drag an image from Finder onto the canvas; confirm an image block appears (Task 13).
7. Copy styled text from Safari, focus the canvas, ⇧⌥⌘V; confirm new paragraph blocks appear (Task 15).
8. Select a block, ⌘C, paste into TextEdit; confirm both HTML and plain text land (Task 16).
9. Make an edit; confirm the titlebar shows the edited dot (Task 17).
10. ⌘F on the canvas; confirm the find bar appears and WebKit highlights a match (Task 19).

Record the outcome (pass/fail per step) in the eventual PR body's Test plan section, same as PR1's own manual-smoke disclosure.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteToolbarItemID.swift Tests/AnglesiteCoreTests/SiteToolbarItemIDTests.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1588): add a customizable toolbar item for the block palette"
```

---

## Final verification (run once, after all 20 tasks)

```bash
swift test --package-path .
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
cd JS/wysiwyg-engine && npm run lint && npm run typecheck && npm test
```

Expected: all green. Then follow CONTRIBUTING.md's PR preparation — the PR body must use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan) and, per this PR's own dependency-ordering note (PR2 of 3, PR3 follows), the body should **not** contain a closing keyword for #1588 — mirror PR1's `#1400` body, which explicitly says "this PR intentionally does not close #1225" for the same reason.
