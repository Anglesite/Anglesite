# C.11 — Phase C Test Suite (Audit + Gap-Fill) Implementation Plan

**Status:** historical

> **Status: Executed in PR #223.** The test landed as `mapsEveryOperationToItsOpString(operation:expectedOp:)` — the names in the steps below were the proposal (`opMappingCoversAllCases(operation:expected:)`) and have since been reconciled to what shipped. The redundant op assertion was removed from both `usesContextSelectorAndMapsOp` and `bareTagBuildsMinimalElementInfo`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the one confirmed Phase C coverage gap — `ApplyEditTool`'s `EditOperation → EditMessage.Op` mapping is asserted for only one of four cases — and verify the audited Phase C coverage stays green.

**Architecture:** The coverage audit is already complete and committed as the spec's coverage map; #161 is otherwise satisfied by existing tests. The only code change is adding one parameterized test in `OnDeviceToolsTests.swift` that exercises all four op-string mappings through `ApplyEditTool.call(arguments:)` via the existing `FakeEditRouter`, and removing the now-redundant single-op assertion. No production code changes.

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing, FoundationModels (compile-gated).

## Global Constraints

- **Toolchain:** All `swift test` commands MUST run under Xcode 27 — prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. The default `xcode-select` path is too old for `#if compiler(>=6.4)` and silently compiles out the code under test. If a run hangs with no output, a stale SwiftPM process may hold the `.build` lock — `pgrep -fl swift-test` and kill the orphan.
- **Compiler gate:** The edited test code stays inside the existing `#if compiler(>=6.4)` block in `OnDeviceToolsTests.swift`.
- **No production changes:** This is a coverage-only task. Do NOT modify `ApplyEditTool.swift` or any `Sources/` file. If the new test reveals a real mapping bug, STOP and report it rather than "fixing" silently.
- **No model needed:** The test uses `FakeEditRouter`, not a `LanguageModelSession`; it runs on CI.
- **No green-coverage padding:** Add exactly the one test the spec identifies. Do not add speculative tests to raise counts.

---

### Task 1: Parameterized op-string mapping test for all EditOperation cases

**Files:**
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` (add one `@Test` to the `ApplyEditToolTests` suite; edit `usesContextSelectorAndMapsOp` at line ~46)

**Interfaces:**
- Consumes (all existing): `FakeEditRouter`, `makeBridge(_:)`, `ApplyEditTool(bridge:siteID:contextSelector:)`, `ApplyEditTool.call(arguments:)`, `GeneratedEditCommand(filePath:selector:operation:value:explanation:)`, `EditOperation` (`.replaceText`/`.replaceAttr`/`.replaceImageSrc`/`.applyInstruction`), `EditMessage.Op` constants (`replaceText="replace-text"`, `replaceAttr="replace-attr"`, `replaceImageSrc="replace-image-src"`, `applyInstruction="apply-instruction"`), `EditReply`, `JSONValue`.
- Produces: no new symbols.

> **Note on TDD:** the production mapping (`ApplyEditTool.opString`) is already correct for all four cases, so this coverage test passes the moment it is written — there is no genuine RED phase. Step 2 is a *deliberate, reverted* mutation check that proves the test is not vacuous, standing in for the RED step.

- [x] **Step 1: Add the parameterized test**

In `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift`, inside the `struct ApplyEditToolTests` suite (e.g. immediately after `usesContextSelectorAndMapsOp`), add:

```swift
    @Test("every EditOperation maps to its EditMessage.Op string",
          arguments: [
              (EditOperation.replaceText, EditMessage.Op.replaceText),
              (EditOperation.replaceAttr, EditMessage.Op.replaceAttr),
              (EditOperation.replaceImageSrc, EditMessage.Op.replaceImageSrc),
              (EditOperation.applyInstruction, EditMessage.Op.applyInstruction),
          ])
    func mapsEveryOperationToItsOpString(operation: EditOperation, expectedOp: String) async throws {
        // Guards the #154 EditOperation → #156 EditMessage.Op vocabulary bridge across all
        // four cases (previously only .replaceText was asserted). Pure routing logic, no model.
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let element: JSONValue = .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md",
            selector: "ignored-by-tool",
            operation: operation,
            value: "v",
            explanation: "why"
        )

        _ = try await tool.call(arguments: cmd)

        #expect(await router.received?.op == expectedOp)
    }
```

- [x] **Step 2: Prove the test is not vacuous (mutation check)**

Temporarily edit `Sources/AnglesiteCore/ApplyEditTool.swift` `opString(for:)` so one case returns the wrong string, e.g. change `case .replaceAttr: return EditMessage.Op.replaceAttr` to `return EditMessage.Op.replaceText`. Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter "mapsEveryOperationToItsOpString"
```
Expected: FAIL on the `.replaceAttr` argument case (`"replace-text"` ≠ `"replace-attr"`). **Then revert the `ApplyEditTool.swift` edit** (`git checkout -- Sources/AnglesiteCore/ApplyEditTool.swift`) — production code must be unchanged.

- [x] **Step 3: Remove the now-redundant single-op assertion**

In `usesContextSelectorAndMapsOp` (`OnDeviceToolsTests.swift:46`), delete this line so op-string mapping is asserted in exactly one place:

```swift
        #expect(msg?.op == "replace-text")
```

Keep that test's other assertions (`msg?.selector`, `msg?.value`, `msg?.path`, `out.contains("Applied")`) — the new test does not cover those.

- [x] **Step 4: Run the ApplyEditTool tests to verify green**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter "ApplyEditTool"
```
Expected: PASS. `mapsEveryOperationToItsOpString` runs four argument cases, all pass; `usesContextSelectorAndMapsOp` still passes with its remaining assertions. Confirm `ApplyEditTool.swift` shows no diff (`git diff --stat Sources/` is empty).

- [x] **Step 5: Commit**

```bash
git add Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "test(intents): cover all EditOperation op-string mappings (#161)

ApplyEditTool maps four EditOperation cases to EditMessage.Op strings but only
.replaceText was asserted. Add a parameterized test over all four cases and
drop the now-redundant single-op assertion. Coverage only; no production change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Full-suite regression + record audit conclusion on #161

**Files:** No code changes. Verification + issue bookkeeping only.

- [x] **Step 1: Run the full suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . 2>&1 | tail -20
```
Expected: all three bundles green; no new failures in `AnglesiteCoreTests` beyond the known plugin-gated e2e tests when `ANGLESITE_PLUGIN_PATH` is unset (see CLAUDE.md). The new `mapsEveryOperationToItsOpString` is included.

- [x] **Step 2: Post the audit conclusion on #161**

```bash
gh issue comment 161 --body "Phase C coverage audit complete (spec: docs/superpowers/specs/2026-06-17-c11-phase-c-test-suite-design.md).

All 7 checklist items are covered by existing tests (coverage map in the spec):
- FoundationModelAssistant, @Generable round-trips, ApplyEditTool/SearchContentTool, alt-text, ContentAssistant/ClaudeAssistant, settings tier, transcript accumulation, chat history.
- ChatModel-the-type glue is app-target (not swift-test reachable); its testable substance is already extracted into ConversationTranscript + ChatHistoryStore + the assistant protocols, all covered.
- Mock LanguageModel seam intentionally deferred to #104.

One real gap was found and filled: ApplyEditTool asserted only .replaceText of four EditOperation→EditMessage.Op mappings — now parameterized across all four. No other gaps; no padding tests added."
```

- [x] **Step 3: No commit** (verification + issue comment only).

---

## Self-Review

**Spec coverage:**
- Audit method + coverage map → already committed in the spec; Task 2 Step 2 records the conclusion on the issue. ✓
- The one gap-fill (parameterized op-string mapping over all 4 cases) → Task 1 Step 1. ✓
- Remove redundant single-op assertion → Task 1 Step 3. ✓
- No production changes / no padding → Global Constraints + Task 1 note. ✓
- Mock seam deferred to #104, ChatModel glue documented as app-target → Task 2 Step 2 comment (mirrors spec). ✓
- Full-suite green verification → Task 2 Step 1. ✓

**Placeholder scan:** No TBD/TODO; the new test's full code is shown; the mutation check names the exact edit and its revert. ✓

**Type consistency:** `EditOperation` cases, `EditMessage.Op` constant names + string values, `GeneratedEditCommand` initializer label order, `FakeEditRouter`/`makeBridge`/`ApplyEditTool` signatures all match the current source verified during the audit. ✓
