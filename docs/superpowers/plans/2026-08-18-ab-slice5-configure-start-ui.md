# A/B slice 5: configure/start lifecycle UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Experiment Results sheet (#769) with a propose → configure → start → running lifecycle, so a site owner can turn an A/B test idea into a live, deployed experiment without leaving the app — per issue [#1518](https://github.com/Anglesite/Anglesite/issues/1518) and the design at `docs/superpowers/specs/2026-08-18-ab-slice5-configure-start-ui-design.md`.

**Architecture:** `ExperimentStatsModel` gains an enum-driven `Step` (propose/configure/starting/running, alongside the unchanged `.manual` #769 fallback) backed by `DomainConfig.Experiments` read/write-through. Configure adds a variant-scaffold function in `AnglesiteCore` and a goal picker whose `visible` kind reuses the Effects Gallery's click-to-place JS↔Swift bridge pattern (a new `GoalElementPickController`/`GoalElementPickMessage` pair) plus a new pure CSS-selector builder. Start writes `status: "running"` and calls the existing `DeployModel.deploy(...)` — no new deploy machinery. A template-side gate extension verifies a picked `visible` selector actually resolves in the built HTML.

**Tech Stack:** Swift 6.4 / SwiftUI (AnglesiteApp, AnglesiteCore, AnglesiteBridge, AnglesiteBridgeCore), TypeScript/vitest (JS/edit-overlay), TypeScript/`node:test` (Resources/Template/scripts).

## Global Constraints

- Read `CONTRIBUTING.md` in this worktree before starting any task — issue claiming, commit format, and PR requirements are mandatory, not optional.
- This work happens in the existing worktree at `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/clever-feistel-56818c` on branch `claude/issue-1518-b22c1b` — every task's steps assume `cd` there first; do not create a nested worktree.
- Conventional commits, subject line ≤72 characters, reference `#1518` where natural (see `CONTRIBUTING.md` ▸ "Commits and pull requests").
- No new third-party dependencies (`CONTRIBUTING.md`: "New dependencies need explicit approval in an issue first") — Task 13's HTML selector check is deliberately regex-based (matching the existing `findCanonicalHref`/`hasNoindexRobotsMeta` idiom in `pre-deploy-check.ts`), not a new HTML-parsing package.
- Goal-picker and lifecycle copy is consequence-phrased throughout — no "selector", "IntersectionObserver", "kind", or other implementation jargon in any owner-facing string (master spec `docs/superpowers/specs/2026-08-16-edge-ab-testing-design.md` §10 item 5).
- Every new interactive SwiftUI control follows the house label/value/hint accessibility pattern (`SyncStatusView.swift:30-34`) and, for selectable rows, `.isSelected` via `.accessibilityAddTraits` on a button-per-row layout (`LicenseGateSheetView.swift:169-195`), not a `Picker`.
- Swift tests use Swift Testing (`import Testing`, `@Test`, `#expect`), matching `ExperimentStatsModelTests.swift`/`EmailSetupModelTests.swift` — not XCTest.
- After any task that touches `Sources/AnglesiteApp` or `Sources/AnglesiteCore`, run `swift test --package-path .` before committing (`Resources/Template/` changes also require this per `CONTRIBUTING.md`).
- After any task that touches `JS/edit-overlay/`, run `npm run lint && npm run typecheck && npm test` from `JS/edit-overlay/`.
- After any task that touches `Resources/Template/scripts/`, run `npx tsx --test Resources/Template/scripts/<file>.test.ts` (or the specific test file for the touched module).

---

### Task 1: `GoalSelectorBuilder` — pure CSS-selector builder

**Files:**
- Create: `Sources/AnglesiteCore/GoalSelectorBuilder.swift`
- Test: `Tests/AnglesiteCoreTests/GoalSelectorBuilderTests.swift`

**Interfaces:**
- Consumes: `ElementInfo`/`AncestorInfo` (already defined in `Sources/AnglesiteCore/PlacementPickMessage.swift`, same module).
- Produces: `GoalSelectorBuilder.build(for: ElementInfo) -> Result<String, GoalSelectorBuilder.BuildError>` — consumed by Task 10 (`GoalElementPickController`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/GoalSelectorBuilderTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct GoalSelectorBuilderTests {
    @Test func prefersDataAnglesiteId() {
        let info = ElementInfo(
            tag: "DIV", id: "reviews", classes: ["astro-abc123", "card"], nthChild: 2,
            ancestors: [], dataAnglesiteId: "reviews-section", dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "[data-anglesite-id=\"reviews-section\"]")
    }

    @Test func fallsBackToIdWhenNoDataAttributes() {
        let info = ElementInfo(
            tag: "SECTION", id: "pricing", classes: [], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "#pricing")
    }

    @Test func fallsBackToRoleAndAriaLabel() {
        let info = ElementInfo(
            tag: "NAV", id: nil, classes: [], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: "navigation", ariaLabel: "Primary", textContent: nil)
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "[role=\"navigation\"][aria-label=\"Primary\"]")
    }

    @Test func filtersAstroScopedHashClassesAndUsesStableClasses() {
        let info = ElementInfo(
            tag: "DIV", id: nil, classes: ["astro-xY9z1", "testimonial-card"], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "div.testimonial-card")
    }

    @Test func fallsBackToTagAndNthChildWithAncestorChain() {
        let ancestor = AncestorInfo(tag: "SECTION", id: "testimonials", classes: [], nthChild: 3, role: nil, ariaLabel: nil)
        let info = ElementInfo(
            tag: "P", id: nil, classes: ["astro-only"], nthChild: 2,
            ancestors: [ancestor], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "#testimonials > p:nth-child(2)")
    }

    @Test func noStableIdentifierAnywhereInChainFails() {
        let ancestor = AncestorInfo(tag: "DIV", id: nil, classes: ["astro-x"], nthChild: 1, role: nil, ariaLabel: nil)
        let info = ElementInfo(
            tag: "SPAN", id: nil, classes: ["astro-y"], nthChild: 1,
            ancestors: [ancestor], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        // No ancestor to anchor on and the leaf has no stable identifier either: falls back to a
        // bare tag:nth-child chain rather than failing — still buildable, just less specific.
        #expect(try? GoalSelectorBuilder.build(for: info).get() == "div:nth-child(1) > span:nth-child(1)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter GoalSelectorBuilderTests`
Expected: FAIL — `GoalSelectorBuilder` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/GoalSelectorBuilder.swift
import Foundation

/// Builds a literal CSS-selector string for the A/B testing "visible" goal (#1270 slice 5) from
/// the same `ElementInfo`/`AncestorInfo` payload `PlacementPickMessage` already decodes. Reuses
/// the proven priority order documented in `JS/edit-overlay/src/selector.ts`
/// (`data-anglesite-id` > `data-testid` > `#id` > `role`/`aria-label` > stable classes >
/// `tag:nth-child`) — nothing before this emitted a literal selector string; the two adjacent
/// mechanisms (the sidecar's `selector.mjs`, `PlacementMatcher`) resolve to a source-file patch
/// location or a `PageModel` node id instead. Astro's dev-time `astro-*` scoped-class hashes are
/// filtered before the class fallback is tried, since they don't survive `astro build`.
public enum GoalSelectorBuilder {
    public enum BuildError: Error, Equatable {}

    /// Anchors on the nearest ancestor (searching nearest-first) with a stable single-element
    /// identifier, then walks down to the leaf with `>` combinators, using each hop's own
    /// simple-selector. If no ancestor anchors, walks the *entire* chain (root-first) the same
    /// way — always succeeds; the result may just be a longer nth-child chain.
    public static func build(for element: ElementInfo) -> Result<String, BuildError> {
        if let leaf = anchoredSelector(tag: element.tag, id: element.id, classes: element.classes,
                                        dataAnglesiteId: element.dataAnglesiteId, dataTestId: element.dataTestId,
                                        role: element.role, ariaLabel: element.ariaLabel, nthChild: element.nthChild) {
            return .success(leaf)
        }
        // No anchor at the leaf: find the nearest ancestor (search reversed — ancestors is
        // root-first) that anchors, then join from there down through to the leaf.
        for (index, ancestor) in element.ancestors.enumerated().reversed() {
            if let anchor = anchoredSelector(tag: ancestor.tag, id: ancestor.id, classes: ancestor.classes ?? [],
                                              dataAnglesiteId: nil, dataTestId: nil,
                                              role: ancestor.role, ariaLabel: ancestor.ariaLabel, nthChild: ancestor.nthChild) {
                let remaining = element.ancestors[(index + 1)...].map { simpleSelector(for: $0) } + [simpleSelector(for: element)]
                return .success(([anchor] + remaining).joined(separator: " > "))
            }
        }
        // No anchor anywhere: full chain from the root-most ancestor down to the leaf.
        let chain = element.ancestors.map { simpleSelector(for: $0) } + [simpleSelector(for: element)]
        return .success(chain.joined(separator: " > "))
    }

    /// A simple selector that alone identifies the element (a data attribute, `#id`, or
    /// `role`+`aria-label` pair) — or `nil` if it has none, meaning the caller must fall back to
    /// stable classes or `tag:nth-child` (never "anchoring" material on their own).
    private static func anchoredSelector(
        tag: String, id: String?, classes: [String], dataAnglesiteId: String?, dataTestId: String?,
        role: String?, ariaLabel: String?, nthChild: Int
    ) -> String? {
        if let dataAnglesiteId, !dataAnglesiteId.isEmpty { return "[data-anglesite-id=\"\(dataAnglesiteId)\"]" }
        if let dataTestId, !dataTestId.isEmpty { return "[data-testid=\"\(dataTestId)\"]" }
        if let id, !id.isEmpty { return "#\(id)" }
        if let role, let ariaLabel, !role.isEmpty, !ariaLabel.isEmpty {
            return "[role=\"\(role)\"][aria-label=\"\(ariaLabel)\"]"
        }
        return nil
    }

    /// A simple selector for one hop in a combinator chain — always succeeds (falls back to
    /// `tag:nth-child(n)`), unlike `anchoredSelector` which only returns something when the
    /// element is identifiable on its own.
    private static func simpleSelector(for info: ElementInfo) -> String {
        simpleSelector(tag: info.tag, classes: info.classes, nthChild: info.nthChild)
    }
    private static func simpleSelector(for ancestor: AncestorInfo) -> String {
        simpleSelector(tag: ancestor.tag, classes: ancestor.classes ?? [], nthChild: ancestor.nthChild ?? 1)
    }
    private static func simpleSelector(tag: String, classes: [String], nthChild: Int) -> String {
        let lowered = tag.lowercased()
        let stableClasses = classes.filter { !$0.hasPrefix("astro-") }
        if !stableClasses.isEmpty { return lowered + stableClasses.map { ".\($0)" }.joined() }
        return "\(lowered):nth-child(\(nthChild))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter GoalSelectorBuilderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/GoalSelectorBuilder.swift Tests/AnglesiteCoreTests/GoalSelectorBuilderTests.swift
git commit -m "feat(#1518): add GoalSelectorBuilder for visible-goal targeting"
```

---

### Task 2: `GoalElementPickMessage` + dispatcher wiring

**Files:**
- Create: `Sources/AnglesiteCore/GoalElementPickMessage.swift`
- Modify: `Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift`
- Test: `Tests/AnglesiteCoreTests/GoalElementPickMessageTests.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift` (add cases to existing suite — read the file first to match its exact style)

**Interfaces:**
- Consumes: nothing new (mirrors `PlacementPickMessage`, `Sources/AnglesiteCore/PlacementPickMessage.swift`).
- Produces: `GoalElementPickMessage` struct + `.decode(from:)`; `AnglesiteMessageDispatcher.GoalElementPickHandler = @Sendable (GoalElementPickMessage) async -> Void`; new `dispatch(...)` parameter `onGoalElementPick:`; new `DispatchResult` cases `.goalElementPickHandled`/`.goalElementPickDropped`; new `RejectionReason` case `.goalElementPickDecode(...)`. Consumed by Task 3 (`AnglesiteScriptHandler`).

- [ ] **Step 1: Write the failing test for the message type**

```swift
// Tests/AnglesiteCoreTests/GoalElementPickMessageTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct GoalElementPickMessageTests {
    @Test func decodesAWellFormedBody() {
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element",
            "path": "/",
            "selector": ["tag": "SECTION", "nthChild": 2, "ancestors": []],
        ]
        switch GoalElementPickMessage.decode(from: body) {
        case .success(let message):
            #expect(message.path == "/")
            #expect(message.element.tag == "SECTION")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test func rejectsAnotherMessageTypeAsWrongType() {
        let body: [String: Any] = ["type": "anglesite:pick-placement", "path": "/", "selector": [:]]
        #expect(GoalElementPickMessage.decode(from: body) == .failure(.wrongType))
    }

    @Test func rejectsMissingSelectorAsMalformed() {
        let body: [String: Any] = ["type": "anglesite:pick-goal-element", "path": "/"]
        #expect(GoalElementPickMessage.decode(from: body) == .failure(.malformed))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter GoalElementPickMessageTests`
Expected: FAIL — `GoalElementPickMessage` doesn't exist yet.

- [ ] **Step 3: Implement `GoalElementPickMessage`**

```swift
// Sources/AnglesiteCore/GoalElementPickMessage.swift
import Foundation

/// The overlay's goal-element-pick mode (Task 4) reporting a click on an arbitrary element while
/// the owner is choosing the target for an A/B experiment's "visible" goal (#1270 slice 5).
/// Structurally identical to `PlacementPickMessage` (same `ElementInfo` payload, same "no reply
/// sent to the page" contract) but a distinct message type/handler — this pick feeds
/// `GoalSelectorBuilder`, not `PlacementMatcher`/an applied edit.
public struct GoalElementPickMessage: Sendable, Equatable {
    public static let messageType = "anglesite:pick-goal-element"

    public let path: String
    public let element: ElementInfo

    public init(path: String, element: ElementInfo) {
        self.path = path
        self.element = element
    }

    public static func decode(from body: Any) -> Result<GoalElementPickMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let path = dict["path"] as? String,
              let selectorDict = dict["selector"] as? [String: Any],
              let element = ElementInfo.decode(from: selectorDict) else {
            return .failure(.malformed)
        }
        return .success(GoalElementPickMessage(path: path, element: element))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter GoalElementPickMessageTests`
Expected: PASS

- [ ] **Step 5: Read the dispatcher file, then wire the new message type in**

Read `Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift` in full first — it has a `PlacementPickHandler` typealias, an `onPlacementPick` parameter on `dispatch(...)`, a `case EditMessage.MessageType...`-style `switch typeStr` branch for `PlacementPickMessage.messageType`, `DispatchResult` cases `.placementPickHandled`/`.placementPickDropped`, and a `RejectionReason` case `.placementPickDecode`. Add the mirror for `GoalElementPickMessage` at each of those four sites, following the exact same shape:

```swift
// Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift — additive changes only

// 1. New typealias, alongside `PlacementPickHandler`:
public typealias GoalElementPickHandler = @Sendable (GoalElementPickMessage) async -> Void

// 2. New case in `DispatchResult`, alongside `.placementPickHandled`/`.placementPickDropped`:
case goalElementPickHandled
case goalElementPickDropped

// 3. New case in `RejectionReason`, alongside `.placementPickDecode`:
case goalElementPickDecode(ComponentCanvasDecodeError)

// 4. New parameter on `dispatch(...)`, alongside `onPlacementPick:`:
onGoalElementPick: GoalElementPickHandler? = nil

// 5. New branch in the `switch typeStr` body, alongside the `PlacementPickMessage.messageType` case:
case GoalElementPickMessage.messageType:
    switch GoalElementPickMessage.decode(from: body) {
    case .success(let message):
        guard let onGoalElementPick else { return .rejected(.notAnObject) } // unreachable in practice; see note below
        await onGoalElementPick(message)
        return .goalElementPickHandled
    case .failure(let error):
        return .rejected(.goalElementPickDecode(error))
    }
```

Before writing branch 5, re-read the *actual* `PlacementPickMessage.messageType` branch — it almost certainly returns `.placementPickDropped` (not a rejection) when `onPlacementPick` is nil, matching `DispatchResult`'s doc comment ("arrived but no handler is installed"). Match that exactly instead of the placeholder shown above — this plan intentionally shows the wrong micro-behavior here as a flag: copy the real nil-handler branch from `PlacementPickMessage`'s case, don't invent a new one.

- [ ] **Step 6: Add dispatcher tests mirroring the existing placement-pick tests**

Open `Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift`, find the placement-pick test(s) (search for `placementPick`), and add the mirror for goal-element-pick: one test that a well-formed `anglesite:pick-goal-element` body with a handler installed calls it and returns `.goalElementPickHandled`; one test that the same body with no handler installed returns `.goalElementPickDropped`.

- [ ] **Step 7: Run the full dispatcher test suite**

Run: `swift test --package-path . --filter AnglesiteMessageDispatcherTests`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/GoalElementPickMessage.swift Sources/AnglesiteBridgeCore/AnglesiteMessageDispatcher.swift Tests/AnglesiteCoreTests/GoalElementPickMessageTests.swift Tests/AnglesiteBridgeCoreTests/AnglesiteMessageDispatcherTests.swift
git commit -m "feat(#1518): wire anglesite:pick-goal-element through the message dispatcher"
```

---

### Task 3: `AnglesiteScriptHandler` — `onGoalElementPick` wiring

**Files:**
- Modify: `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift`

**Interfaces:**
- Consumes: `AnglesiteMessageDispatcher.GoalElementPickHandler` (Task 2).
- Produces: `AnglesiteScriptHandler.GoalElementPickHandler` typealias; `init(...)` and `dispatch(...)`/`userContentController(...)` all accept/forward `onGoalElementPick:`. Consumed by Task 15 (`PreviewView`/`SiteWindow` wiring).

- [ ] **Step 1: Add the typealias and thread the parameter**

Mirror every place `onPlacementPick`/`PlacementPickHandler` appears in `Sources/AnglesiteBridge/AnglesiteScriptHandler.swift` (the `public typealias PlacementPickHandler = ...` near the top, the `private let onPlacementPick`, the `init` parameter, the `static func dispatch` parameter and forwarded call, and the `userContentController` local capture + forwarded call) and add the exact same shape for `onGoalElementPick: AnglesiteMessageDispatcher.GoalElementPickHandler` / `AnglesiteScriptHandler.GoalElementPickHandler`. Also add the two new `DispatchResult` switch cases (`.goalElementPickHandled` → `return`, `.goalElementPickDropped` → log the same shape as `.placementPickDropped`'s log line, with `"goal-element-pick"` in the message).

- [ ] **Step 2: Build**

Run: `swift build --package-path .`
Expected: builds clean — this task has no new tests of its own (it's pure plumbing over Task 2's already-tested dispatcher); Task 2's dispatcher tests plus Task 15's later integration are the coverage for this path.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteBridge/AnglesiteScriptHandler.swift
git commit -m "feat(#1518): thread onGoalElementPick through AnglesiteScriptHandler"
```

---

### Task 4: JS edit-overlay — goal-element pick mode

**Files:**
- Modify: `JS/edit-overlay/src/messages.ts`
- Modify: `JS/edit-overlay/src/overlay.ts`
- Test: `JS/edit-overlay/test/overlay-goal-pick.test.ts` (new file, mirroring `JS/edit-overlay/test/overlay-placement-pick.test.ts`)

**Interfaces:**
- Consumes: `elementInfoFor` (`JS/edit-overlay/src/selector.ts`, unchanged).
- Produces: `postGoalElementPick` (messages.ts); `installGoalPickMode(win)` returning `{enter, exit}`, exposed as `window.anglesite._enterGoalPickMode`/`_exitGoalPickMode` (overlay.ts). Consumed by Task 15's `evaluateJavaScript` calls.

- [ ] **Step 1: Read the existing placement-pick test for the pattern to mirror**

Read `JS/edit-overlay/test/overlay-placement-pick.test.ts` in full before writing Step 2 — match its DOM setup, `postMessage` stubbing, and assertion style exactly.

- [ ] **Step 2: Write the failing test**

```typescript
// JS/edit-overlay/test/overlay-goal-pick.test.ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { installGoalPickMode, GOAL_PICK_HOVER_CLASS } from "../src/overlay.js";

describe("installGoalPickMode", () => {
  beforeEach(() => {
    document.body.innerHTML = `<section id="reviews"><p>Great product</p></section>`;
  });

  it("does nothing on click before enter() is called", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    installGoalPickMode(win);
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("posts anglesite:pick-goal-element for the clicked element while active", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(1);
    expect((posted[0] as any).type).toBe("anglesite:pick-goal-element");
    expect((posted[0] as any).selector.tag).toBe("P");
  });

  it("stops posting after exit()", () => {
    const posted: unknown[] = [];
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: (m: unknown) => posted.push(m) } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    controls.exit();
    document.querySelector("p")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(posted).toHaveLength(0);
  });

  it("adds a hover outline class to the candidate element while active, and clears it on mouseout", () => {
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: vi.fn() } } } } as any;
    const controls = installGoalPickMode(win);
    controls.enter();
    const p = document.querySelector("p")!;
    p.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(true);
    p.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(p.classList.contains(GOAL_PICK_HOVER_CLASS)).toBe(false);
  });

  it("exposes window.anglesite._enterGoalPickMode/_exitGoalPickMode", () => {
    const win = { webkit: { messageHandlers: { anglesite: { postMessage: vi.fn() } } } } as any;
    installGoalPickMode(win);
    expect(typeof win.anglesite._enterGoalPickMode).toBe("function");
    expect(typeof win.anglesite._exitGoalPickMode).toBe("function");
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd JS/edit-overlay && npm test -- overlay-goal-pick`
Expected: FAIL — `installGoalPickMode`/`GOAL_PICK_HOVER_CLASS` don't exist yet.

- [ ] **Step 4: Add `postGoalElementPick` to messages.ts**

```typescript
// JS/edit-overlay/src/messages.ts — add alongside PlacementPickMessage/postPlacementPick

export interface GoalElementPickMessage {
  id: string;
  type: "anglesite:pick-goal-element";
  path: string;
  selector: ElementInfo;
}

/** Posts a goal-element-pick report to native — same "no reply" contract as
 *  `postPlacementPick`; the app resolves the pick into a CSS selector and updates its own UI. */
export function postGoalElementPick(
  message: GoalElementPickMessage,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.anglesite;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
}
```

- [ ] **Step 5: Implement `installGoalPickMode` in overlay.ts**

```typescript
// JS/edit-overlay/src/overlay.ts — add near installPlacementPickMode; also add
// `postGoalElementPick` to the existing `import { ... } from "./messages.js"` block.

export const GOAL_PICK_HOVER_CLASS = "anglesite-goal-pick-hover";

export interface GoalPickControls {
  enter(): void;
  exit(): void;
}

/** Goal-element-pick mode (#1270 slice 5): while active, hovering any element outlines it and a
 *  click reports its `ElementInfo` via `anglesite:pick-goal-element` instead of the normal
 *  click-to-edit path — same exclusivity contract as `installPlacementPickMode`, entered only via
 *  an explicit native call. Adds hover feedback placement-pick mode doesn't have, since "point at
 *  the reviews section" is materially harder to do accurately with no visual confirmation of the
 *  candidate element before clicking. */
export function installGoalPickMode(win: Window & typeof globalThis = window): GoalPickControls {
  let active = false;
  let hovered: Element | null = null;

  const clearHover = () => {
    hovered?.classList.remove(GOAL_PICK_HOVER_CLASS);
    hovered = null;
  };

  document.addEventListener("mouseover", (ev) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    if (hovered && hovered !== target) hovered.classList.remove(GOAL_PICK_HOVER_CLASS);
    target.classList.add(GOAL_PICK_HOVER_CLASS);
    hovered = target;
  });
  document.addEventListener("mouseout", (ev) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (target === hovered) clearHover();
  });

  const clickHandler = (ev: MouseEvent) => {
    if (!active) return;
    const target = ev.target as Element | null;
    if (!target || target.nodeType !== 1) return;
    ev.preventDefault();
    ev.stopPropagation();
    clearHover();
    postGoalElementPick(
      {
        id: nextEditID(),
        type: "anglesite:pick-goal-element",
        path: location.pathname,
        selector: elementInfoFor(target),
      },
      win as unknown as Parameters<typeof postGoalElementPick>[1],
    );
  };
  document.addEventListener("click", clickHandler, { capture: true });

  const anglesiteWin = win as unknown as { anglesite?: { _enterGoalPickMode?: () => void; _exitGoalPickMode?: () => void } };
  anglesiteWin.anglesite = anglesiteWin.anglesite ?? {};
  const controls: GoalPickControls = {
    enter: () => { active = true; },
    exit: () => { active = false; clearHover(); },
  };
  anglesiteWin.anglesite._enterGoalPickMode = controls.enter;
  anglesiteWin.anglesite._exitGoalPickMode = controls.exit;
  return controls;
}
```

Also add a style rule for `GOAL_PICK_HOVER_CLASS` inside `installStyles()`'s joined array, matching `HOVER_CLASS`'s existing rule shape (e.g. a distinct outline color so it's visually distinguishable from ordinary click-to-edit hover — `outline: 2px dashed rgba(255, 149, 0, 0.9); outline-offset: 2px; cursor: pointer;`), and call `installGoalPickMode(window)` from `install()` alongside the existing `installPlacementPickMode(window)` call.

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd JS/edit-overlay && npm test -- overlay-goal-pick`
Expected: PASS

- [ ] **Step 7: Lint and typecheck**

Run: `cd JS/edit-overlay && npm run lint && npm run typecheck`
Expected: clean

- [ ] **Step 8: Commit**

```bash
git add JS/edit-overlay/src/messages.ts JS/edit-overlay/src/overlay.ts JS/edit-overlay/test/overlay-goal-pick.test.ts
git commit -m "feat(#1518): add goal-element pick mode to the edit overlay"
```

---

### Task 5: `NativeContentOperations.duplicatePageAsVariant`

**Files:**
- Modify: `Sources/AnglesiteCore/NativeContentOperations.swift` (add the method next to `duplicatePage`, so it can reach that file's `private` `write(_:to:)`/`gitCommit(...)`/`siteDirectory(_:)` helpers)
- Test: `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (add cases to the existing suite — read it first for the exact fixture/temp-directory pattern already used for `duplicatePage`)

**Interfaces:**
- Consumes: `ContentScaffold.normalizeRoute`/`slugify`/`pageRelativePath` (`ContentScaffold.swift`), `ContentScanner.routeFromPagePath` (`ContentScanner.swift:66`), `RobotsConfigFile.apply` (`RobotsConfigStore.swift:191-215`), `FileDocumentIO.load` (`FileDocumentIO.swift:30`).
- Produces: `NativeContentOperations.duplicatePageAsVariant(siteID:relativePath:experimentID:variantID:) async -> ContentCreateResult`. Consumed by Task 12 (`ExperimentStatsModel`'s configure step).

- [ ] **Step 1: Read the existing `duplicatePage` tests to match the fixture pattern**

Read the `duplicatePage` test(s) in `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` in full — note how they build a temp site directory, what `siteDirectory(_:)` resolves against, and how they assert on `ContentCreateResult`.

- [ ] **Step 2: Write the failing tests**

```swift
// Add to Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift — reuse this suite's
// existing temp-site-directory helper (whatever it's actually called after Step 1's read)
// instead of the placeholder `makeTempSite` name below if the real helper differs.

@Test func duplicatePageAsVariantWritesADeterministicRoute() async throws {
    let (ops, root) = try makeTempSite()
    let controlRelPath = "src/pages/pricing.astro"
    let controlContents = """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout title="Pricing">
      <h1>Pricing</h1>
    </BaseLayout>
    """
    try controlContents.write(
        to: root.appendingPathComponent(controlRelPath), atomically: true, encoding: .utf8)

    let result = await ops.duplicatePageAsVariant(
        siteID: "s1", relativePath: controlRelPath, experimentID: "homepage-hero", variantID: "b")

    guard case .created(let filePath, let identifier) = result else {
        Issue.record("expected .created, got \(result)")
        return
    }
    #expect(filePath == "src/pages/x/homepage-hero/b.astro")
    #expect(identifier == "/x/homepage-hero/b")
}

@Test func duplicatePageAsVariantInjectsCanonicalPathPointingAtControl() async throws {
    let (ops, root) = try makeTempSite()
    let controlRelPath = "src/pages/pricing.astro"
    try """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout title="Pricing">
      <h1>Pricing</h1>
    </BaseLayout>
    """.write(to: root.appendingPathComponent(controlRelPath), atomically: true, encoding: .utf8)

    _ = await ops.duplicatePageAsVariant(
        siteID: "s1", relativePath: controlRelPath, experimentID: "homepage-hero", variantID: "b")

    let written = try String(
        contentsOf: root.appendingPathComponent("src/pages/x/homepage-hero/b.astro"), encoding: .utf8)
    #expect(written.contains("<BaseLayout canonicalPath=\"/pricing\" title=\"Pricing\">"))
}

@Test func duplicatePageAsVariantWritesANoindexRobotsConfigEntry() async throws {
    let (ops, root) = try makeTempSite()
    let controlRelPath = "src/pages/pricing.astro"
    try """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout title="Pricing">
      <h1>Pricing</h1>
    </BaseLayout>
    """.write(to: root.appendingPathComponent(controlRelPath), atomically: true, encoding: .utf8)

    _ = await ops.duplicatePageAsVariant(
        siteID: "s1", relativePath: controlRelPath, experimentID: "homepage-hero", variantID: "b")

    let config = RobotsConfigFile.read(under: root)
    #expect(config.noindex.contains { $0.path == "/x/homepage-hero/b/" })
}

@Test func duplicatePageAsVariantFailsOnRouteCollision() async throws {
    let (ops, root) = try makeTempSite()
    let controlRelPath = "src/pages/pricing.astro"
    try "content".write(to: root.appendingPathComponent(controlRelPath), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("src/pages/x/homepage-hero"), withIntermediateDirectories: true)
    try "existing".write(
        to: root.appendingPathComponent("src/pages/x/homepage-hero/b.astro"), atomically: true, encoding: .utf8)

    let result = await ops.duplicatePageAsVariant(
        siteID: "s1", relativePath: controlRelPath, experimentID: "homepage-hero", variantID: "b")

    guard case .failed = result else {
        Issue.record("expected .failed on route collision, got \(result)")
        return
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path . --filter NativeContentOperationsTests`
Expected: FAIL — `duplicatePageAsVariant` doesn't exist yet.

- [ ] **Step 4: Implement `duplicatePageAsVariant`**

```swift
// Sources/AnglesiteCore/NativeContentOperations.swift — add immediately after duplicatePage(...)

/// Scaffolds an A/B-test variant page from an existing control page (#1270 slice 5): reads the
/// control's contents, writes them to the deterministic route `/x/<experimentID>/<variantID>`
/// (never the collision-bumping "Copy 2" naming `duplicatePage` uses — an experiment's variant
/// route is part of its identity, not a display name), injects a `canonicalPath` prop into the
/// `<BaseLayout` invocation pointing back at the control route, and marks the new route noindex
/// via `RobotsConfigFile` — the same mechanism the app's page inspector uses (#1093), so the
/// variant is invisible to search from the moment it's written, with no separate "remember to
/// noindex it" step. Fails rather than overwriting if the target route is already taken.
public func duplicatePageAsVariant(
    siteID: String, relativePath: String, experimentID: String, variantID: String
) async -> ContentCreateResult {
    guard let root = await siteDirectory(siteID) else { return .siteNotFound }
    let sourceAbs = root.appendingPathComponent(relativePath)
    guard fileManager.fileExists(atPath: sourceAbs.path) else {
        return .failed(reason: "No page exists at \(relativePath)")
    }
    let contents: String
    do { contents = try FileDocumentIO.load(sourceAbs, fileManager: fileManager).contents }
    catch { return .failed(reason: "\(error)") }

    let route = ContentScaffold.normalizeRoute("/x/\(experimentID)/\(variantID)")
    let relPath = ContentScaffold.pageRelativePath(normalizedRoute: route)
    guard !fileManager.fileExists(atPath: root.appendingPathComponent(relPath).path) else {
        return .failed(reason: "A variant page already exists at \(relPath)")
    }

    let controlRoute = ContentScanner.routeFromPagePath(relativePath)
    guard let injected = Self.injectingCanonicalPath(controlRoute, into: contents) else {
        return .failed(reason: "Couldn't find a <BaseLayout> invocation to attach the variant's canonical link to")
    }

    do { try write(injected, to: root.appendingPathComponent(relPath)) }
    catch { return .failed(reason: "\(error)") }

    do {
        try RobotsConfigFile.apply(
            source: .page(file: relPath), noindex: true, disallowCrawl: false, path: route, under: root)
    } catch { return .failed(reason: "\(error)") }

    _ = await gitCommit(root, relPath, "anglesite: scaffold experiment variant \(route)")
    return .created(filePath: relPath, identifier: route)
}

/// Inserts `canonicalPath="<controlRoute>"` as the first attribute of the first `<BaseLayout`
/// opening tag found, or `nil` if the source has no `<BaseLayout` invocation to attach to (an
/// `.astro` page not using the standard layout — out of scope for a v1 variant scaffold, matching
/// `PageTitleEditor.RewriteError.noEditableLocation`'s "never invent a location" stance).
static func injectingCanonicalPath(_ controlRoute: String, into contents: String) -> String? {
    guard let range = contents.range(of: "<BaseLayout") else { return nil }
    let escaped = controlRoute.replacingOccurrences(of: "\"", with: "&quot;")
    return contents.replacingCharacters(
        in: range, with: "<BaseLayout canonicalPath=\"\(escaped)\"")
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter NativeContentOperationsTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/NativeContentOperations.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(#1518): add duplicatePageAsVariant for A/B test scaffolding"
```

---

### Task 6: `BaseLayout.astro` — `canonicalPath` override prop

**Files:**
- Modify: `Resources/Template/src/layouts/BaseLayout.astro`
- Test: check for an existing `BaseLayout` build/snapshot test (search `Resources/Template` for `BaseLayout.test` or similar before writing Step 1) and add a case there; if none exists, this task's verification is Step 3's manual build check plus Task 13's gate test, which exercises this prop end-to-end.

**Interfaces:**
- Consumes: nothing new.
- Produces: `Props.canonicalPath?: string` on `BaseLayout`. Consumed by Task 5's scaffolded variant pages.

- [ ] **Step 1: Search for existing BaseLayout tests**

Run: `find Resources/Template -iname "*baselayout*test*"`
If a file is found, read it and add a case asserting that a page passing `canonicalPath="/pricing"` renders `<link rel="canonical" href=".../pricing">` instead of its own URL. If none is found, skip to Step 2 — this prop is exercised indirectly by Task 13's dist-content gate test, which is the real regression backstop for it.

- [ ] **Step 2: Add the prop**

```astro
---
// Resources/Template/src/layouts/BaseLayout.astro — inside `interface Props { ... }`, add:
  /**
   * Overrides the canonical URL this page advertises, as a root-relative path (e.g. `/pricing`).
   * Omit for ordinary pages, which canonicalize to their own URL. Set by a scaffolded A/B-test
   * variant page (#1270 slice 5) to point back at the control page it was duplicated from — a
   * variant must never rank in search as a distinct page from its control.
   */
  canonicalPath?: string;
---
```

```astro
---
// Resources/Template/src/layouts/BaseLayout.astro — replace the existing single-line `canonical`
// computation (around line 100) with:
const { canonicalPath } = Astro.props;
const canonical = canonicalPath
  ? new URL(canonicalPath, Astro.site ?? Astro.url).href
  : new URL(Astro.url.pathname, Astro.site ?? Astro.url).href;
---
```

- [ ] **Step 3: Build the template and confirm no regression**

Run: `cd Resources/Template && npm run build`
Expected: builds clean; every existing page (none of which pass `canonicalPath`) renders byte-identical canonical links to before this change.

- [ ] **Step 4: Commit**

```bash
git add Resources/Template/src/layouts/BaseLayout.astro
git commit -m "feat(#1518): add canonicalPath override prop to BaseLayout"
```

---

### Task 7: Sitemap excludes noindexed routes

**Files:**
- Modify: `Resources/Template/src/lib/sitemap-data.ts`
- Test: `Resources/Template/src/lib/sitemap.test.ts` (add cases — read the file first for its existing fixture/assertion pattern)

**Interfaces:**
- Consumes: `readRobotsConfig` (`Resources/Template/src/lib/robots-config.ts`, already imported by `BaseLayout.astro`).
- Produces: `staticPaths()` (private to `sitemap-data.ts`) now excludes noindexed routes. No public signature change — `getSitemapUrls` keeps its existing signature.

- [ ] **Step 1: Read the existing sitemap test file**

Read `Resources/Template/src/lib/sitemap.test.ts` in full to match its fixture/mocking style for `import.meta.glob`-backed page files and for reading/writing `src/data/robots-config.json`.

- [ ] **Step 2: Write the failing test**

```typescript
// Add to Resources/Template/src/lib/sitemap.test.ts — adapt the exact mocking mechanism to
// whatever Step 1 found `PAGE_FILES`/`getSitemapUrls` already use in this file's existing tests.
test("excludes a route with a noindex robots-config entry from the sitemap", async () => {
  // Arrange: a robots-config.json with one noindexed route, matching an existing page fixture.
  // (Reuse this file's existing fixture-writing helper for src/data/robots-config.json, or write
  // one directly to the temp cwd this suite already sets up, if Step 1 found no reusable helper.)
  await writeRobotsConfig({ noindex: [{ path: "/x/homepage-hero/b/" }], disallow: [], extra: [] });

  const urls = await getSitemapUrls("https://example.com");

  expect(urls.some((u) => u.loc.includes("/x/homepage-hero/b"))).toBe(false);
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test src/lib/sitemap.test.ts` (or the project's actual test invocation for this file, per `Tests` section of `CONTRIBUTING.md` — confirm with `cat package.json`'s `scripts.test` if unsure)
Expected: FAIL — the noindexed route still appears in `urls`.

- [ ] **Step 4: Implement the filter**

```typescript
// Resources/Template/src/lib/sitemap-data.ts
import { readRobotsConfig } from "./robots-config.ts";

function withTrailingSlash(path: string): string {
  return path.endsWith("/") ? path : path + "/";
}

/** Routes for the pages that exist in this site, dynamic routes and 404 excluded, and any route
 *  the site has marked noindex (#1270 slice 5's gate requirement: a scaffolded A/B-test variant
 *  page must never appear in the sitemap — this is the general mechanism, not experiment-specific,
 *  since a noindexed page belongs in neither search results nor the sitemap that feeds them). */
function staticPaths(): string[] {
  const noindexed = new Set(
    readRobotsConfig(process.cwd()).noindex.map((entry) => withTrailingSlash(entry.path)));
  return Object.keys(PAGE_FILES)
    .map(routePathForPage)
    .filter((path): path is string => path !== undefined)
    .filter((path) => !noindexed.has(withTrailingSlash(path)));
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Resources/Template && npx tsx --test src/lib/sitemap.test.ts`
Expected: PASS — and confirm no existing sitemap test regressed (full file run).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/lib/sitemap-data.ts Resources/Template/src/lib/sitemap.test.ts
git commit -m "feat(#1518): exclude noindexed routes from the sitemap"
```

---

### Task 8: `checkExperiments` — visible-goal dist selector-resolution check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts`
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: `checkExperiments`'s existing `controlHtmlContent`/`variantHtmlContent`/`distPathFor`/`Issue` (already defined in this file, per the read in this plan's research phase — `checkExperiments` at `pre-deploy-check.ts:846`).
- Produces: no new exported symbol — extends `checkExperiments`'s existing body with one more check inside its `goal.kind === "visible"` branch (dist-check section, after line ~1077 in the current file).

- [ ] **Step 1: Read the existing `checkExperiments` client-goal-beacon block for the pattern to mirror**

Re-read `pre-deploy-check.ts` lines ~1079–1107 (the `CLIENT_GOAL_KINDS.has(goal.kind)` block) immediately before writing code — the new check's shape (iterate `[control, variant]` × `[html, roleLabel, distPath]`, push an `Issue` per failing arm) should match it closely.

- [ ] **Step 2: Write the failing tests**

```typescript
// Add to Resources/Template/scripts/pre-deploy-check.test.ts, near the existing checkExperiments
// tests (search for `checkExperiments(` to find them and match their exact fixture-building style
// for `active` entries and HTML content strings).

test("checkExperiments flags a visible-goal selector that matches neither built page", () => {
  const active = [{
    id: "homepage-hero", name: "Hero", page: "/", split: 0.5, status: "running", startedAt: "2026-08-01",
    variant: { id: "b", name: "B", page: "/x/homepage-hero/b/" },
    goal: { kind: "visible", selector: "#reviews" },
  }];
  const config = JSON.stringify({ version: 1, experiments: { active } });
  const distFiles = new Set(["dist/index.html", "dist/x/homepage-hero/b/index.html"]);
  const controlHtml = "<html><body><h1>Home</h1></body></html>";
  const variantHtml = "<html><body><h1>Home (variant)</h1></body></html>";

  const issues = checkExperiments(config, distFiles, variantHtml, null, controlHtml);

  assert.ok(issues.some((i) => i.category === "experiments-goal-beacon" && i.message.includes("#reviews")));
});

test("checkExperiments passes a visible-goal selector present in both built pages", () => {
  const active = [{
    id: "homepage-hero", name: "Hero", page: "/", split: 0.5, status: "running", startedAt: "2026-08-01",
    variant: { id: "b", name: "B", page: "/x/homepage-hero/b/" },
    goal: { kind: "visible", selector: "#reviews" },
  }];
  const config = JSON.stringify({ version: 1, experiments: { active } });
  const distFiles = new Set(["dist/index.html", "dist/x/homepage-hero/b/index.html"]);
  const controlHtml = '<html><body><section id="reviews">Great</section></body></html>';
  const variantHtml = '<html><body><section id="reviews">Great</section></body></html>';

  const issues = checkExperiments(config, distFiles, variantHtml, null, controlHtml);

  assert.ok(!issues.some((i) => i.category === "experiments-goal-beacon" && i.message.includes("reviews")));
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — the first test finds no matching issue yet (the check doesn't exist).

- [ ] **Step 4: Implement the check**

```typescript
// Resources/Template/scripts/pre-deploy-check.ts — inside checkExperiments, immediately after the
// existing CLIENT_GOAL_KINDS block (after the closing brace around line 1107), before `return issues;`

  // A "visible" goal's selector must actually resolve against BOTH built pages — the owner picks
  // it against the dev-server preview (Anglesite app, #1270 slice 5), which is not guaranteed to
  // match the production build's DOM 1:1 (Astro's dev-time scoped-class hashes, in particular). A
  // selector that only ever matched the preview is a goal that silently never fires — the same
  // failure class the beacon-tag check above guards against.
  if (goal.kind === "visible" && typeof goal.selector === "string") {
    const selector = goal.selector as string;
    for (const [html, roleLabel, distPath] of [
      [controlHtmlContent, "control page", distPathFor(page)],
      [variantHtmlContent, "variant page", distPathFor(variantPage)],
    ] as const) {
      if (html !== null && !selectorLikelyMatchesHtml(html, selector)) {
        issues.push({
          severity: "error",
          category: "experiments-goal-beacon",
          message: `Running experiment's "visible" goal selector (${JSON.stringify(selector)}) doesn't match anything in the built ${roleLabel} ("${roleLabel === "control page" ? page : variantPage}") — this goal can never fire.`,
          file: distPath,
          remediation: "Re-pick the element in the app, or hand-edit the selector to match markup that exists in the built page.",
        });
      }
    }
  }
```

```typescript
// Resources/Template/scripts/pre-deploy-check.ts — new helper function, near
// findCanonicalHref/hasNoindexRobotsMeta (same regex-tag-isolation idiom, deliberately not a full
// CSS selector engine — see this plan's Global Constraints on new dependencies). Only checks the
// selector's LAST (leaf/target) simple-selector component, since that's the element the beacon's
// `document.querySelector` ultimately needs to find visible on screen — the combinator chain's
// ancestor relationships aren't independently verified, a documented, deliberate simplification.

const LEAF_ATTR_PATTERN = /^\[([\w-]+)="([^"]*)"\]$/;
const LEAF_ID_PATTERN = /^#([\w-]+)$/;
const LEAF_ROLE_ARIA_PATTERN = /^\[role="([^"]*)"\]\[aria-label="([^"]*)"\]$/;
const LEAF_TAG_CLASSES_PATTERN = /^([a-z0-9]+)((?:\.[\w-]+)*)$/;

function selectorLikelyMatchesHtml(html: string, selector: string): boolean {
  const leaf = selector.split(" > ").pop() ?? selector;
  const tagPattern = /<[a-zA-Z][^>]*>/g;
  let m: RegExpExecArray | null;

  const attrMatch = leaf.match(LEAF_ATTR_PATTERN);
  const idMatch = leaf.match(LEAF_ID_PATTERN);
  const roleAriaMatch = leaf.match(LEAF_ROLE_ARIA_PATTERN);
  const tagClassesMatch = leaf.match(LEAF_TAG_CLASSES_PATTERN);

  while ((m = tagPattern.exec(html)) !== null) {
    const tag = m[0];
    if (attrMatch && new RegExp(`\\b${attrMatch[1]}\\s*=\\s*["']${escapeRegExp(attrMatch[2])}["']`).test(tag)) return true;
    if (idMatch && new RegExp(`\\bid\\s*=\\s*["']${escapeRegExp(idMatch[1])}["']`).test(tag)) return true;
    if (roleAriaMatch
        && new RegExp(`\\brole\\s*=\\s*["']${escapeRegExp(roleAriaMatch[1])}["']`).test(tag)
        && new RegExp(`\\baria-label\\s*=\\s*["']${escapeRegExp(roleAriaMatch[2])}["']`).test(tag)) return true;
    if (tagClassesMatch) {
      const [, tagName, dotClasses] = tagClassesMatch;
      const classes = dotClasses.split(".").filter(Boolean);
      const tagMatches = new RegExp(`^<${tagName}\\b`, "i").test(tag);
      const classMatch = tag.match(/\bclass\s*=\s*["']([^"']*)["']/i);
      const tagClasses = classMatch ? classMatch[1].split(/\s+/) : [];
      if (tagMatches && classes.every((c) => tagClasses.includes(c))) return true;
      if (tagMatches && classes.length === 0) return true; // bare tag:nth-child(n) fallback
    }
  }
  return false;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — and confirm the full `pre-deploy-check.test.ts` suite still passes (no regression in the existing `checkExperiments` cases).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#1518): gate-check visible-goal selectors against built HTML"
```

---

### Task 9: `LiveRegionAnnouncer` — experiment lifecycle transitions

**Files:**
- Modify: `Sources/AnglesiteCore/LiveRegionAnnouncer.swift`
- Test: `Tests/AnglesiteCoreTests/LiveRegionAnnouncerTests.swift` (add cases — read the file first for its existing pattern)

**Interfaces:**
- Consumes: nothing new.
- Produces: `LiveRegionAnnouncer.ExperimentActivity` enum + `LiveRegionAnnouncer.experimentAnnouncement(from:to:) -> String?`. Consumed by Task 14 (`ExperimentStatsSheetView`'s `.onChange(of: model.step)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/AnglesiteCoreTests/LiveRegionAnnouncerTests.swift
@Test func experimentStartRunningIsAnnounced() {
    let announcement = LiveRegionAnnouncer.experimentAnnouncement(from: .configuring, to: .running(name: "Hero headline"))
    #expect(announcement == "Your test is live. I'll tell you when there's a clear answer.")
}

@Test func experimentDeployFailureIsAnnounced() {
    let announcement = LiveRegionAnnouncer.experimentAnnouncement(from: .starting, to: .failed(reason: "Deploy blocked"))
    #expect(announcement == "Couldn't start your test. Deploy blocked")
}

@Test func noAnnouncementForANonTransition() {
    #expect(LiveRegionAnnouncer.experimentAnnouncement(from: .configuring, to: .configuring) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LiveRegionAnnouncerTests`
Expected: FAIL — `ExperimentActivity`/`experimentAnnouncement` don't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/LiveRegionAnnouncer.swift — add a new `// MARK: Experiment lifecycle`
// section, following the same shape as `// MARK: Deploy` above it.

/// The announceable substrate of the experiment configure/start lifecycle (#1270 slice 5),
/// mapped from `ExperimentStatsModel.Step` the same way `DeployActivity` maps from
/// `DeployModel.Phase`. `.inactive` covers `.manual`/`.propose`/`.idle`-shaped states with
/// nothing worth announcing.
public enum ExperimentActivity: Equatable {
    case inactive
    case configuring
    case starting
    case running(name: String)
    case failed(reason: String)
}

/// The announcement for an experiment lifecycle transition, or `nil`. Same "coarse transition,
/// not per-field" rule as `deployAnnouncement`.
public static func experimentAnnouncement(from old: ExperimentActivity, to new: ExperimentActivity) -> String? {
    guard old != new else { return nil }
    switch new {
    case .running: return "Your test is live. I'll tell you when there's a clear answer."
    case .failed(let reason): return "Couldn't start your test. \(reason)"
    case .configuring, .starting, .inactive: return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LiveRegionAnnouncerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LiveRegionAnnouncer.swift Tests/AnglesiteCoreTests/LiveRegionAnnouncerTests.swift
git commit -m "feat(#1518): announce experiment lifecycle transitions"
```

---

### Task 10: `GoalElementPickController`

**Files:**
- Create: `Sources/AnglesiteApp/GoalElementPickController.swift`
- Test: `Tests/AnglesiteAppTests/GoalElementPickControllerTests.swift`

**Interfaces:**
- Consumes: `GoalSelectorBuilder.build(for:)` (Task 1), `GoalElementPickMessage` (Task 2).
- Produces: `GoalElementPickController` with `state: State { idle, picking, succeeded(selector: String), failed(String) }`, `startPicking(enterOverlayMode:exitOverlayMode:)`, `cancel()`, `acknowledge()`, `handlePick(_:)`. Consumed by Task 12 (`ExperimentStatsModel`) and Task 15 (`SiteWindow` wiring).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteAppTests/GoalElementPickControllerTests.swift
import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@MainActor
@Suite struct GoalElementPickControllerTests {
    private func elementInfo(id: String?) -> ElementInfo {
        ElementInfo(tag: "SECTION", id: id, classes: [], nthChild: 1, ancestors: [],
                    dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil)
    }

    @Test func startPickingEntersOverlayModeAndSetsPicking() {
        let controller = GoalElementPickController()
        var entered = false
        controller.startPicking(enterOverlayMode: { entered = true }, exitOverlayMode: {})
        #expect(entered)
        #expect(controller.state == .picking)
    }

    @Test func startPickingIsANoOpWhenAlreadyPicking() {
        let controller = GoalElementPickController()
        var enterCount = 0
        controller.startPicking(enterOverlayMode: { enterCount += 1 }, exitOverlayMode: {})
        controller.startPicking(enterOverlayMode: { enterCount += 1 }, exitOverlayMode: {})
        #expect(enterCount == 1)
    }

    @Test func cancelExitsOverlayModeAndReturnsToIdle() {
        let controller = GoalElementPickController()
        var exited = false
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.cancel()
        #expect(exited)
        #expect(controller.state == .idle)
    }

    @Test func handlePickBuildsASelectorAndExitsOverlayMode() {
        let controller = GoalElementPickController()
        var exited = false
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        #expect(exited)
        #expect(controller.state == .succeeded(selector: "#reviews"))
    }

    @Test func handlePickIsANoOpWhenNotPicking() {
        let controller = GoalElementPickController()
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        #expect(controller.state == .idle)
    }

    @Test func acknowledgeReturnsATerminalStateToIdle() {
        let controller = GoalElementPickController()
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: {})
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        controller.acknowledge()
        #expect(controller.state == .idle)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter GoalElementPickControllerTests`
Expected: FAIL — `GoalElementPickController` doesn't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/GoalElementPickController.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the click-to-select flow for an A/B experiment's "visible" goal (#1270 slice 5):
/// enters the overlay's goal-pick mode, waits for a click, and builds a CSS selector from it via
/// `GoalSelectorBuilder`. Simpler than `EffectPlacementController` — no page-model fetch or
/// applied edit, just a synchronous pure computation on the reported `ElementInfo`. One instance
/// per `ExperimentStatsModel` (Task 12).
@MainActor
@Observable
public final class GoalElementPickController {
    public enum State: Equatable {
        case idle
        case picking
        case succeeded(selector: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    private var exitOverlayMode: (() -> Void)?

    public init() {}

    public func startPicking(enterOverlayMode: @escaping () -> Void, exitOverlayMode: @escaping () -> Void) {
        guard case .idle = state else { return }
        self.exitOverlayMode = exitOverlayMode
        state = .picking
        enterOverlayMode()
    }

    public func cancel() {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .idle
    }

    /// Dismisses a terminal state (`.succeeded`/`.failed`) back to `.idle` — mirrors
    /// `EffectPlacementController.acknowledge()`'s reasoning: without this, `startPicking`'s
    /// `.idle` guard would refuse every pick after the first for the rest of this instance's life.
    public func acknowledge() {
        switch state {
        case .succeeded, .failed: state = .idle
        case .idle, .picking: return
        }
    }

    public func handlePick(_ message: GoalElementPickMessage) {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        switch GoalSelectorBuilder.build(for: message.element) {
        case .success(let selector): state = .succeeded(selector: selector)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter GoalElementPickControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/GoalElementPickController.swift Tests/AnglesiteAppTests/GoalElementPickControllerTests.swift
git commit -m "feat(#1518): add GoalElementPickController for the visible-goal picker"
```

---

### Task 11: `ExperimentStatsModel` — Step enum, config loading, propose

**Files:**
- Modify: `Sources/AnglesiteApp/ExperimentStatsModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:724-726` (`presentExperimentStats()` needs to pass `sourceDirectory`)
- Test: `Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift` (extend the existing suite)

**Interfaces:**
- Consumes: `DomainConfigStore(sourceDirectory:).load()` (`DomainConfigStore.swift:40`), `DomainConfig.Experiments.Experiment` (`DomainConfig.swift:218-249`), `ContentScaffold.slugify` (`ContentScaffold.swift:36`).
- Produces: `ExperimentStatsModel.Step` enum, `ExperimentStatsModel.Draft` struct, `init(siteID:sourceDirectory:currentRoute:)`, `propose(from:)`/`proposeCustom(name:)`, `goalPickController: GoalElementPickController` (Task 10). Consumed by Task 12 (configure actions, same model), Task 14 (views), Task 15 (`SiteWindowModel` wiring).

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift — note the existing tests all
// construct `ExperimentStatsModel(siteID: "s1")`; after this task, the initializer gains
// `sourceDirectory`/`currentRoute` parameters, so update those existing call sites too (with
// defaulted params if that's the least-invasive way to keep them compiling, decided during
// implementation — but the model's actual step-resolution logic must be exercised with a real
// temp directory, not defaults, in the NEW tests below).

@Test func withNoConfigStartsInManual() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    #expect(model.step == .manual)
}

@Test func withADraftExperimentStartsInConfigure() throws {
    let tmp = try tempDirectory()
    let experiment = DomainConfig.Experiments.Experiment(
        id: "homepage-hero", name: "Hero headline", page: "/",
        variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
        split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "draft")
    DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [experiment]) }

    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    guard case .configure(let draft) = model.step else {
        Issue.record("expected .configure, got \(model.step)")
        return
    }
    #expect(draft.id == "homepage-hero")
}

@Test func withARunningExperimentStartsInRunning() throws {
    let tmp = try tempDirectory()
    let experiment = DomainConfig.Experiments.Experiment(
        id: "homepage-hero", name: "Hero headline", page: "/",
        variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
        split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"),
        status: "running", startedAt: "2026-08-01")
    DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [experiment]) }

    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    guard case .running(let running) = model.step else {
        Issue.record("expected .running, got \(model.step)")
        return
    }
    #expect(running.id == "homepage-hero")
}

@Test func proposeFromASuggestionMovesToConfigureWithASlugifiedID() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.propose(from: ExperimentStats.suggestionPlaybook[0]) // "Hero headline"
    guard case .configure(let draft) = model.step else {
        Issue.record("expected .configure, got \(model.step)")
        return
    }
    #expect(draft.id == "hero-headline")
    #expect(draft.name == "Hero headline")
    #expect(draft.page == "/")
}

private func tempDirectory() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: FAIL — `Step`/`Draft`/the new `init`/`propose(from:)` don't exist yet.

- [ ] **Step 3: Implement the Step enum, Draft struct, loading, and propose**

```swift
// Sources/AnglesiteApp/ExperimentStatsModel.swift — replace the file's contents with the
// existing #769 manual-entry properties/methods UNCHANGED, plus the following additions.

@Observable @MainActor
final class ExperimentStatsModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    let currentRoute: String

    enum Step: Equatable {
        case manual
        case propose
        case configure(Draft)
        case starting
        case running(DomainConfig.Experiments.Experiment)
    }

    struct Draft: Equatable {
        var id: String
        var name: String
        var page: String
        var variantID: String = "b"
        var variantName: String
        var variantPage: String?
        var goalKind: String?
        var goalPath: String?
        var goalDepth: Int?
        var goalSelector: String?

        /// A `draft`-status `DomainConfig.Experiments.Experiment` once the variant is scaffolded
        /// and a goal is picked — `nil` while either is still missing, matching `canStart`'s gate
        /// in Task 13.
        var asExperiment: DomainConfig.Experiments.Experiment? {
            guard let variantPage, let goalKind else { return nil }
            let goal = DomainConfig.Experiments.Experiment.Goal(
                kind: goalKind, path: goalPath, depth: goalDepth, selector: goalSelector)
            return DomainConfig.Experiments.Experiment(
                id: id, name: name, page: page,
                variant: .init(id: variantID, name: variantName, page: variantPage),
                split: 0.5, goal: goal, status: "draft")
        }
    }

    private(set) var step: Step
    let goalPickController = GoalElementPickController()

    // #769 manual-entry fields — unchanged from before this task.
    var experimentName: String = ""
    var controlName: String = "Original"
    var controlImpressions: Int = 0
    var controlConversions: Int = 0
    var treatmentName: String = "Variant"
    var treatmentImpressions: Int = 0
    var treatmentConversions: Int = 0
    private(set) var result: ExperimentStats.Result?
    private(set) var hasSufficientData = false
    private(set) var sampleRatioMismatch = false
    let suggestions = ExperimentStats.suggestionPlaybook

    init(siteID: String, sourceDirectory: URL, currentRoute: String) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.currentRoute = currentRoute
        self.step = Self.resolveInitialStep(sourceDirectory: sourceDirectory)
    }

    private static func resolveInitialStep(sourceDirectory: URL) -> Step {
        guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
              let active = config.experiments?.active?.first else {
            return .manual
        }
        if active.status == "running" { return .running(active) }
        return .configure(Draft(
            id: active.id, name: active.name, page: active.page,
            variantID: active.variant.id, variantName: active.variant.name, variantPage: active.variant.page,
            goalKind: active.goal.kind, goalPath: active.goal.path,
            goalDepth: active.goal.depth, goalSelector: active.goal.selector))
    }

    func openPropose() {
        guard case .manual = step else { return }
        step = .propose
    }

    func propose(from suggestion: ExperimentStats.Suggestion) {
        proposeCustom(name: suggestion.title)
    }

    func proposeCustom(name: String) {
        let slug = ContentScaffold.slugify(name)
        step = .configure(Draft(id: slug, name: name, page: currentRoute, variantName: "\(name) — variant"))
    }

    // ... canAnalyze/analyze()/summary/editAgain() unchanged from before this task ...
}
```

- [ ] **Step 4: Update `SiteWindowModel.presentExperimentStats()`**

```swift
// Sources/AnglesiteApp/SiteWindowModel.swift:724-726 — replace with:
func presentExperimentStats() {
    guard experimentStatsModel == nil, let site else { return }
    experimentStatsModel = ExperimentStatsModel(
        siteID: site.id, sourceDirectory: site.sourceDirectory, currentRoute: preview.activeRoute ?? "/")
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: PASS. Also run the full app-target suite once to confirm `SiteWindowModel`'s call-site update didn't break anything else: `swift test --package-path .`

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ExperimentStatsModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift
git commit -m "feat(#1518): add lifecycle Step and propose to ExperimentStatsModel"
```

---

### Task 12: `ExperimentStatsModel` — configure actions

**Files:**
- Modify: `Sources/AnglesiteApp/ExperimentStatsModel.swift`
- Test: `Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift`

**Interfaces:**
- Consumes: `NativeContentOperations.duplicatePageAsVariant` (Task 5), `DomainConfigStore.update(sourceDirectory:_:)` (`DomainConfigStore+Update.swift:31-35`), `GoalElementPickController.state` (Task 10).
- Produces: `scaffoldVariant() async`, `setPageviewGoal(path:)`, `setScrollGoal(depth:)`, `applyPickedVisibleGoal()`, `canStart: Bool`. Consumed by Task 13 (start), Task 14 (views).

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift
@Test func scaffoldVariantWritesTheVariantPageAndUpdatesTheDraft() async throws {
    let tmp = try tempDirectory()
    try FileManager.default.createDirectory(
        at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
    try """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---
    <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
    """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    await model.scaffoldVariant()

    guard case .configure(let draft) = model.step else {
        Issue.record("expected .configure, got \(model.step)")
        return
    }
    #expect(draft.variantPage == "/x/hero-headline/b")
}

@Test func settingAGoalPersistsTheDraftToConfig() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    // scaffoldVariant is async and file-backed; for this test, set variantPage directly to
    // isolate goal-setting + persistence from the scaffold step already covered above.
    guard case .configure(var draft) = model.step else { Issue.record("expected .configure"); return }
    draft.variantPage = "/x/hero-headline/b"
    model.applyDraftForTesting(draft) // test-only setter; see Step 3's note on exposing this

    model.setPageviewGoal(path: "/contact/thanks/")

    let saved = try DomainConfigStore(sourceDirectory: tmp).load()
    #expect(saved.experiments?.active?.first?.goal.kind == "pageview")
    #expect(saved.experiments?.active?.first?.status == "draft")
}

@Test func canStartOnlyOnceVariantAndGoalAreBothSet() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    #expect(!model.canStart)
    model.setScrollGoal(depth: 75)
    #expect(!model.canStart) // no variantPage yet
}
```

Note on `applyDraftForTesting`: if threading a test-only setter feels wrong once you're in the code, an equally valid alternative is to make the second test above `async` and call the real `scaffoldVariant()` against a temp fixture (same shape as the first test) instead of a synthetic draft — pick whichever keeps `Draft`'s mutation surface entirely private to the model's own methods, which is the better invariant to protect. Either way, no production code should exist solely to make a test possible.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: FAIL — the new methods don't exist yet.

- [ ] **Step 3: Implement configure actions**

```swift
// Sources/AnglesiteApp/ExperimentStatsModel.swift — add to the class

private let contentOps = NativeContentOperations()

func scaffoldVariant() async {
    guard case .configure(var draft) = step, draft.variantPage == nil else { return }
    let controlRelPath = "src/pages\(draft.page == "/" ? "/index" : draft.page).astro"
    let result = await contentOps.duplicatePageAsVariant(
        siteID: siteID, relativePath: controlRelPath, experimentID: draft.id, variantID: draft.variantID)
    guard case .created(_, let route) = result else { return }
    draft.variantPage = route
    step = .configure(draft)
    persistDraft(draft)
}

func setPageviewGoal(path: String) {
    updateDraftGoal { $0.goalKind = "pageview"; $0.goalPath = path; $0.goalDepth = nil; $0.goalSelector = nil }
}

func setScrollGoal(depth: Int) {
    updateDraftGoal { $0.goalKind = "scroll"; $0.goalDepth = depth; $0.goalPath = nil; $0.goalSelector = nil }
}

/// Call after `goalPickController.state` reaches `.succeeded(selector:)` — the sheet view's
/// `.onChange(of: goalPickController.state)` is the caller (Task 14).
func applyPickedVisibleGoal() {
    guard case .succeeded(let selector) = goalPickController.state else { return }
    updateDraftGoal { $0.goalKind = "visible"; $0.goalSelector = selector; $0.goalPath = nil; $0.goalDepth = nil }
    goalPickController.acknowledge()
}

private func updateDraftGoal(_ mutate: (inout Draft) -> Void) {
    guard case .configure(var draft) = step else { return }
    mutate(&draft)
    step = .configure(draft)
    persistDraft(draft)
}

private func persistDraft(_ draft: Draft) {
    guard let experiment = draft.asExperiment else { return }
    DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
}

var canStart: Bool {
    guard case .configure(let draft) = step else { return false }
    return draft.asExperiment != nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ExperimentStatsModel.swift Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift
git commit -m "feat(#1518): add configure actions to ExperimentStatsModel"
```

---

### Task 13: `ExperimentStatsModel` — start + deploy observation

**Files:**
- Modify: `Sources/AnglesiteApp/ExperimentStatsModel.swift`
- Test: `Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift`

**Interfaces:**
- Consumes: `DeployModel.Phase` (`DeployModel.swift:22-31`), `DeployModel.deploy(siteID:siteDirectory:configDirectory:currentRoutes:...)` (`DeployModel.swift:275-282`).
- Produces: `ExperimentStatsModel.start(deploy: (String, URL, URL, [String]) -> Void)`, `observeDeployPhase(_:)`. Consumed by Task 14 (views/`.onChange` wiring), Task 15 (`SiteWindow` passing the real `DeployModel`).

- [ ] **Step 1: Write the failing tests**

```swift
// Add to Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift
@Test func startWritesRunningStatusAndInvokesDeploy() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    guard case .configure(var draft) = model.step else { Issue.record("expected .configure"); return }
    draft.variantPage = "/x/hero-headline/b"
    draft.goalKind = "pageview"; draft.goalPath = "/thanks/"
    model.applyDraftForTesting(draft)

    var deployCalled = false
    model.start(deploy: { _, _, _, _ in deployCalled = true })

    guard case .starting = model.step else { Issue.record("expected .starting, got \(model.step)"); return }
    #expect(deployCalled)
    let saved = try DomainConfigStore(sourceDirectory: tmp).load()
    #expect(saved.experiments?.active?.first?.status == "running")
}

@Test func deploySuccessMovesToRunning() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    guard case .configure(var draft) = model.step else { Issue.record("expected .configure"); return }
    draft.variantPage = "/x/hero-headline/b"
    draft.goalKind = "pageview"; draft.goalPath = "/thanks/"
    model.applyDraftForTesting(draft)
    model.start(deploy: { _, _, _, _ in })

    model.observeDeployPhase(.succeeded(url: URL(string: "https://example.com")!, duration: 1))

    guard case .running(let experiment) = model.step else { Issue.record("expected .running, got \(model.step)"); return }
    #expect(experiment.status == "running")
}

@Test func deployFailureRevertsToConfigureWithoutClearingTheDraft() throws {
    let tmp = try tempDirectory()
    let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
    model.proposeCustom(name: "Hero headline")
    guard case .configure(var draft) = model.step else { Issue.record("expected .configure"); return }
    draft.variantPage = "/x/hero-headline/b"
    draft.goalKind = "pageview"; draft.goalPath = "/thanks/"
    model.applyDraftForTesting(draft)
    model.start(deploy: { _, _, _, _ in })

    model.observeDeployPhase(.failed(reason: "Network error", exitCode: nil))

    guard case .configure(let reverted) = model.step else { Issue.record("expected .configure, got \(model.step)"); return }
    #expect(reverted.variantPage == "/x/hero-headline/b")
    let saved = try DomainConfigStore(sourceDirectory: tmp).load()
    #expect(saved.experiments?.active?.first?.status == "draft")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: FAIL — `start(deploy:)`/`observeDeployPhase(_:)` don't exist yet.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteApp/ExperimentStatsModel.swift — add to the class

/// Flips the draft's status to `running`, persists it, and invokes `deploy` — a closure rather
/// than a direct `DeployModel` dependency so this model stays testable without constructing one
/// (`DeployModel` pulls in token/license/container machinery none of this model's own logic
/// needs). `SiteWindow` (Task 15) supplies the real `DeployModel.deploy(...)` call; the view's
/// own `.onChange(of: deployModel.phase)` then calls `observeDeployPhase(_:)` below.
func start(deploy: (String, URL, URL, [String]) -> Void) {
    guard case .configure(let draft) = step, var experiment = draft.asExperiment else { return }
    experiment.status = "running"
    experiment.startedAt = ISO8601DateFormatter().string(from: Date()).prefix(10).description
    DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
    step = .starting
    deploy(siteID, sourceDirectory, sourceDirectory, [experiment.page, experiment.variant.page])
}

/// Called from the sheet view's `.onChange(of: deployModel.phase)` while `step == .starting`.
/// Any phase other than a clean success reverts to `.configure` with the draft intact and its
/// config entry rolled back to `"draft"` — a failed start must never leave `anglesite.json`
/// claiming a test is live when the deploy that would make it so never landed.
func observeDeployPhase(_ phase: DeployModel.Phase) {
    guard case .starting = step else { return }
    switch phase {
    case .succeeded:
        guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
              let running = config.experiments?.active?.first else { return }
        step = .running(running)
    case .failed(let reason, _):
        revertToConfigureAfterFailedStart(reason: reason)
    case .blocked:
        revertToConfigureAfterFailedStart(reason: "The pre-deploy check found issues that need fixing first.")
    case .idle, .running, .workerNameConflict, .webmentionPaidPlanConfirmationNeeded, .domainConfigDrift:
        return
    }
}

private func revertToConfigureAfterFailedStart(reason: String) {
    guard case .starting = step,
          let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
          let entry = config.experiments?.active?.first else { return }
    DomainConfigStore.update(sourceDirectory: sourceDirectory) { config in
        var reverted = entry
        reverted.status = "draft"
        reverted.startedAt = nil
        config.experiments = .init(active: [reverted])
    }
    step = .configure(Draft(
        id: entry.id, name: entry.name, page: entry.page,
        variantID: entry.variant.id, variantName: entry.variant.name, variantPage: entry.variant.page,
        goalKind: entry.goal.kind, goalPath: entry.goal.path,
        goalDepth: entry.goal.depth, goalSelector: entry.goal.selector))
    startFailureReason = reason
}

private(set) var startFailureReason: String?
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ExperimentStatsModelTests`
Expected: PASS. Then run the full suite once: `swift test --package-path .`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ExperimentStatsModel.swift Tests/AnglesiteAppTests/ExperimentStatsModelTests.swift
git commit -m "feat(#1518): add start and deploy-phase observation to ExperimentStatsModel"
```

---

### Task 14: Views — propose/configure/running + sheet wiring

**Files:**
- Modify: `Sources/AnglesiteApp/ExperimentStatsSheetView.swift`
- Create: `Sources/AnglesiteApp/ExperimentProposeView.swift`
- Create: `Sources/AnglesiteApp/ExperimentConfigureView.swift`
- Create: `Sources/AnglesiteApp/ExperimentRunningStatusView.swift`

**Interfaces:**
- Consumes: `ExperimentStatsModel.Step`/`.Draft` (Task 11-13), `GoalElementPickController.state` (Task 10), `LiveRegionAnnouncer.experimentAnnouncement` (Task 9).
- Produces: the three new views; `ExperimentStatsSheetView` switches on `model.step`. Consumed by Task 15 (needs `deployModel`/pick-mode closures threaded in from `SiteWindow`).

This task is UI-only (no unit tests — SwiftUI view bodies aren't practically unit-testable here, matching this codebase's existing convention of no tests for `ExperimentStatsSheetView`/`EmailSetupSheetView` themselves). Verification is a manual smoke pass in Step 4.

- [ ] **Step 1: Rewrite `ExperimentStatsSheetView` to switch on `model.step`**

```swift
// Sources/AnglesiteApp/ExperimentStatsSheetView.swift
import SwiftUI
import AnglesiteCore

struct ExperimentStatsSheetView: View {
    @Bindable var model: ExperimentStatsModel
    var deployModel: DeployModel
    var onDone: () -> Void
    var enterGoalPickMode: () -> Void
    var exitGoalPickMode: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .manual:
                    manualForm
                case .propose:
                    ExperimentProposeView(model: model)
                case .configure:
                    ExperimentConfigureView(model: model, enterGoalPickMode: enterGoalPickMode, exitGoalPickMode: exitGoalPickMode)
                case .starting:
                    ProgressView("Starting your test…")
                case .running(let experiment):
                    ExperimentRunningStatusView(experiment: experiment)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Experiment Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
        .onChange(of: model.step) { oldStep, newStep in
            guard AppSettings.shared.announcesLiveUpdates else { return }
            // `newStep`'s activity needs `model.startFailureReason` too: a failed deploy reverts
            // `step` from `.starting` back to `.configure`, which on its own is indistinguishable
            // from a fresh, never-started `.configure` — losing the failure announcement entirely
            // if `activity(for:)` looked at `step` alone. Consumed here (read, not cleared) since
            // `experimentAnnouncement` already dedupes on `old != new`.
            if let announcement = LiveRegionAnnouncer.experimentAnnouncement(
                from: activity(for: oldStep, failureReason: nil),
                to: activity(for: newStep, failureReason: model.startFailureReason)) {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .onChange(of: deployModel.phase) { _, newPhase in
            model.observeDeployPhase(newPhase)
        }
        .onChange(of: model.goalPickController.state) { _, newState in
            if case .succeeded = newState { model.applyPickedVisibleGoal() }
        }
    }

    private func activity(for step: ExperimentStatsModel.Step, failureReason: String?) -> LiveRegionAnnouncer.ExperimentActivity {
        switch step {
        case .manual, .propose: return .inactive
        case .configure:
            // A `.configure` step reached via `observeDeployPhase`'s revert carries a
            // `startFailureReason`; a `.configure` step reached via propose/scaffold/goal-setting
            // never sets one (Task 12's methods don't touch it) — so this alone distinguishes the
            // two without `step` needing its own dedicated `.justFailed` case.
            if let failureReason { return .failed(reason: failureReason) }
            return .inactive
        case .starting: return .starting
        case .running(let e): return .running(name: e.name)
        }
    }

    // manualForm: move the ENTIRE existing #769 body (Section("Experiment") through the
    // "Test ideas" ForEach) into this computed property unchanged, except the "Test ideas"
    // section's rows each gain `.onTapGesture { model.openPropose() }` — the one behavioral
    // change to the manual form: tapping a suggestion now moves into the lifecycle instead of
    // being inert text. Read the CURRENT file (pre-Task-11) before writing this property so the
    // moved code is copied verbatim except for that one addition.
    @ViewBuilder
    private var manualForm: some View {
        // ... existing #769 Form content, verbatim, plus the tap gesture noted above ...
    }
}
```

- [ ] **Step 2: `ExperimentProposeView`**

```swift
// Sources/AnglesiteApp/ExperimentProposeView.swift
import SwiftUI
import AnglesiteCore

struct ExperimentProposeView: View {
    @Bindable var model: ExperimentStatsModel
    @State private var customName = ""

    var body: some View {
        Form {
            Section("What should we test?") {
                ForEach(model.suggestions, id: \.title) { suggestion in
                    Button {
                        model.propose(from: suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.rationale).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion.title)
                    .accessibilityHint(suggestion.rationale)
                }
            }
            Section("Or describe your own idea") {
                TextField("What are you testing?", text: $customName)
                Button("Start with this idea") { model.proposeCustom(name: customName) }
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
```

- [ ] **Step 3: `ExperimentConfigureView`**

```swift
// Sources/AnglesiteApp/ExperimentConfigureView.swift
import SwiftUI
import AnglesiteCore

struct ExperimentConfigureView: View {
    @Bindable var model: ExperimentStatsModel
    var enterGoalPickMode: () -> Void
    var exitGoalPickMode: () -> Void

    @State private var scrollDepth: Double = 75
    @State private var pageviewPath: String = ""

    private var draft: ExperimentStatsModel.Draft? {
        guard case .configure(let draft) = model.step else { return nil }
        return draft
    }

    var body: some View {
        Form {
            if let draft {
                Section(draft.name) {
                    if draft.variantPage == nil {
                        Button("Create the variant page") {
                            Task { await model.scaffoldVariant() }
                        }
                    } else {
                        LabeledContent("Variant page", value: draft.variantPage ?? "")
                        Text("Edit its content from the page editor, then choose what counts as a win below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("What counts as a win?") {
                    goalOptionRow(
                        title: "Counts when a visitor reaches a page",
                        isSelected: draft.goalKind == "pageview") {
                        TextField("Page (e.g. /contact/thanks/)", text: $pageviewPath)
                        Button("Use this page") { model.setPageviewGoal(path: pageviewPath) }
                            .disabled(pageviewPath.isEmpty)
                    }
                    goalOptionRow(
                        title: "Counts when a visitor scrolls partway down",
                        isSelected: draft.goalKind == "scroll") {
                        Slider(value: $scrollDepth, in: 1...100, step: 1) {
                            Text("Scroll depth")
                        }
                        Button("Use \(Int(scrollDepth))% scrolled") { model.setScrollGoal(depth: Int(scrollDepth)) }
                    }
                    goalOptionRow(
                        title: "Counts when a visitor sees something on the page",
                        isSelected: draft.goalKind == "visible") {
                        Button(model.goalPickController.state == .picking ? "Click the element in the preview…" : "Choose in the preview") {
                            model.goalPickController.startPicking(enterOverlayMode: enterGoalPickMode, exitOverlayMode: exitGoalPickMode)
                        }
                        .disabled(model.goalPickController.state == .picking)
                        if case .failed(let reason) = model.goalPickController.state {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button("Start your test") {
                        model.start(deploy: { _, _, _, _ in }) // Task 15 supplies the real deploy call
                    }
                    .disabled(!model.canStart)
                }
            }
        }
    }

    @ViewBuilder
    private func goalOptionRow<Content: View>(title: String, isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) {
            Label(title, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            content()
        }
    }
}
```

- [ ] **Step 4: `ExperimentRunningStatusView`**

```swift
// Sources/AnglesiteApp/ExperimentRunningStatusView.swift
import SwiftUI
import AnglesiteCore

struct ExperimentRunningStatusView: View {
    let experiment: DomainConfig.Experiments.Experiment

    var body: some View {
        Form {
            Section(experiment.name) {
                LabeledContent("Status") {
                    Text("Live")
                }
                .accessibilityLabel("Status")
                .accessibilityValue("Live")
                if let startedAt = experiment.startedAt {
                    LabeledContent("Started", value: startedAt)
                }
                Text("Your test is live. Visitors will see one version or the other; I'll tell you when there's a clear answer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean. (Task 15 still needs to update the `ExperimentStatsSheetView` call site in `SiteWindow.swift` for the new `deployModel`/`enterGoalPickMode`/`exitGoalPickMode` parameters — this build may fail at that one call site until Task 15 lands; if so, that's expected and gets fixed there, not here.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ExperimentStatsSheetView.swift Sources/AnglesiteApp/ExperimentProposeView.swift Sources/AnglesiteApp/ExperimentConfigureView.swift Sources/AnglesiteApp/ExperimentRunningStatusView.swift
git commit -m "feat(#1518): add propose/configure/running views to the Experiment Results sheet"
```

---

### Task 15: `SiteWindow`/`SiteWindowModel` wiring

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:936-937` (sheet call site), `:69` region of `PreviewView.swift` construction site (~line 1188-1195)
- Modify: `Sources/AnglesiteApp/PreviewView.swift` (new `onGoalElementPick` param)
- Modify: `Sources/AnglesiteApp/ComponentEditorCanvasPane.swift:219` (pass `onGoalElementPick: nil` explicitly if the parameter isn't defaulted — check after Task 3/this task's `AnglesiteScriptHandler` signature)

**Interfaces:**
- Consumes: everything from Tasks 10-14.
- Produces: fully wired feature — this is the integration task with no new public API of its own.

- [ ] **Step 1: Add `onGoalElementPick` to `PreviewView`**

```swift
// Sources/AnglesiteApp/PreviewView.swift — add near `onPlacementPick` (both the doc comment and
// default-no-op shape should mirror it):
var onGoalElementPick: AnglesiteScriptHandler.GoalElementPickHandler = { _ in }
```

And thread it into the `AnglesiteScriptHandler(...)` construction at line 69:

```swift
let handler = AnglesiteScriptHandler(
    router: router, onVisibleElements: onVisibleElements,
    onPlacementPick: onPlacementPick, onGoalElementPick: onGoalElementPick)
```

- [ ] **Step 2: Wire the closures in `SiteWindow.swift`'s `previewPane(for:)`**

```swift
// Sources/AnglesiteApp/SiteWindow.swift — inside previewPane(for:)'s PreviewView(...) call
// (around line 1188), add alongside the existing onPlacementPick:
onGoalElementPick: { message in
    model.experimentStatsModel?.goalPickController.handlePick(message)
},
```

- [ ] **Step 3: Pass `deployModel` and the goal-pick enter/exit closures into the sheet**

```swift
// Sources/AnglesiteApp/SiteWindow.swift:936-937 — replace with:
.sheet(item: $bindableModel.experimentStatsModel) { statsModel in
    ExperimentStatsSheetView(
        model: statsModel,
        deployModel: model.deploy,
        onDone: { model.experimentStatsModel = nil },
        enterGoalPickMode: {
            model.preview.webView?.evaluateJavaScript("window.anglesite?._enterGoalPickMode?.()")
        },
        exitGoalPickMode: {
            model.preview.webView?.evaluateJavaScript("window.anglesite?._exitGoalPickMode?.()")
        }
    )
}
```

- [ ] **Step 4: Wire `start()`'s deploy closure to the real `DeployModel`**

In `ExperimentConfigureView.swift` (Task 14 Step 3), the `Button("Start your test")` action currently calls `model.start(deploy: { _, _, _, _ in })` with a stub. Replace it with the real deploy call — this needs `deployModel` threaded into `ExperimentConfigureView` the same way it's already threaded into `ExperimentStatsSheetView` (Task 14 Step 1). Add a `var deployModel: DeployModel` param to `ExperimentConfigureView`, pass it from `ExperimentStatsSheetView`'s `case .configure:` branch, and change the button action to:

```swift
Button("Start your test") {
    model.start(deploy: { siteID, siteDirectory, configDirectory, routes in
        deployModel.deploy(siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory, currentRoutes: routes)
    })
}
.disabled(!model.canStart)
```

- [ ] **Step 5: Confirm `ComponentEditorCanvasPane.swift`'s `AnglesiteScriptHandler(...)` call still compiles**

Read `Sources/AnglesiteApp/ComponentEditorCanvasPane.swift:219` — if `onGoalElementPick` was given a default `= nil` in Task 3 (the plan's `init` mirrors `onPlacementPick`, which does have one), this call site needs no change. Confirm by building; if it fails to compile, add `onGoalElementPick: nil` explicitly to that call site.

- [ ] **Step 6: Build and run the full local test suite**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Run: `swift test --package-path .`
Expected: both clean.

- [ ] **Step 7: Manual smoke test**

Per `docs/testing-macos-app.md`, launch the built app against a real (or fixture) site, open Website ▸ Experiment Results…, and walk propose → configure → pick a `visible` goal by clicking an element in the live preview → start, confirming: the variant page appears in the Navigator, the goal picker's hover outline shows in the preview during picking, and the sheet reaches the running-status view after a successful (or intentionally-failed, to check the revert path) deploy. This is the one path in this plan with no automated DOM to assert against (per the design doc §8), so it needs a real look before merging.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/PreviewView.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/ExperimentConfigureView.swift Sources/AnglesiteApp/ComponentEditorCanvasPane.swift
git commit -m "feat(#1518): wire configure/start lifecycle UI into SiteWindow"
```

---

## After all tasks

- Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" before opening the PR — use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan), note in "Paired PR check" that this is app/template-only with no MCP schema change, and include `Closes #1518` per the template's closing-keyword requirement.
- Confirm the `🛠️ In Progress` label stays on issue #1518 (already applied) — don't remove it; the PR's closing keyword drops it out of the claimed-issue search on merge.
- Run the full verification sweep once more before opening the PR: `swift test --package-path .`, `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, `cd JS/edit-overlay && npm run lint && npm run typecheck && npm test`, and the `Resources/Template` test command(s) used in Tasks 6-8.
