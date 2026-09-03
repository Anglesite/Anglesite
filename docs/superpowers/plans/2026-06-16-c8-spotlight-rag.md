# C.8 — Local RAG via SpotlightSearchTool Implementation Plan (v2)

**Status:** historical

> **Status: Executed in PR #220.** Steps are checked below. Two deviations from the steps as written: the work landed as separate commits (not the single amended commit the steps suggested), and PR review added a `spotlightToolDisplayName` constant for the `.started` label plus clarifying comments on the `tools.isEmpty` branch, the `supportsTools` MAS caveat, and the budget-fit test's `guard case`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach Apple's built-in `SpotlightSearchTool` to the `FoundationModelAssistant` **conversational** session — configured to fit the on-device context window — so the on-device model gets local RAG over the Core Spotlight index that `ContentSpotlightIndexer` populates.

**Architecture:** The default `SpotlightSearchTool()` injects a ~13k-token guidance manual that blows the on-device 4,096-token budget, so it must be built with `guide: .focused(.items)` / `.compact`. Even slimmed it costs budget, so it attaches **only** to the `converse` session (via a `makeSession(includeSpotlight:)` flag), not the one-shot `generate`/`generateStructured` paths. `capabilities.supportsTools` becomes `true` (the conversational session always carries ≥1 tool); `attachedToolNames` (used only in the `.started` event on `converse`) always begins with a Spotlight label.

**Tech Stack:** Swift 6.4 / Xcode 27, `FoundationModels`, `CoreSpotlight`, Swift Testing.

**Starting point:** Branch `siri-ai/c8-spotlight-rag-158` is at commit `3b1ae44`, which implemented an earlier (now-revised) "always attach, default config" draft. This plan brings that code to the v2 design. Amend `3b1ae44` into one clean commit at the end (the branch is not pushed).

## Global Constraints

- **Toolchain:** All `swift test` commands MUST run under Xcode 27 — prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. The default `xcode-select` path is too old for `#if compiler(>=6.4)` and silently compiles out the code under test. If a run hangs with no output, a stale SwiftPM process may hold the `.build` lock — `pgrep -fl swift-test` and kill the orphan.
- **Compiler gate:** All edited code lives inside the existing `#if compiler(>=6.4)` block.
- **No new dependencies:** `CoreSpotlight` + `FoundationModels` are system frameworks already linked.
- **Config is load-bearing:** `SpotlightSearchTool` MUST be built with `guide: .init(level: .focused(.items), format: .compact)`. A bare `SpotlightSearchTool()` regresses to a 13k-token overflow that breaks every conversational turn — verified empirically.
- **Scope:** Only Spotlight attachment changes. Do NOT alter when `ApplyEditTool`/`SearchContentTool` attach (they remain gated on `editBridge`+`contentGraph`, on all paths, as before).

---

### Task 1: Configure SpotlightSearchTool and attach it on the conversational path only

**Files:**
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift`, `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift`

**Interfaces:**
- Consumes: `FoundationModelAssistant.init(tier:editBridge:contentGraph:)`, `ApplyEditTool.toolName`, `SearchContentTool.toolName`, `SpotlightSearchTool(configuration:)`, `SystemLanguageModel.default.availability`.
- Produces: `capabilities.supportsTools == true` for all dependency configs; `makeSession(context:includeSpotlight:)` attaches the configured Spotlight tool only when `includeSpotlight == true`; `conversationSession(for:)` passes `includeSpotlight: true`; one-shot `generate`/`generateStructured` carry no Spotlight tool. No new public symbols.

- [x] **Step 1: Update `makeSession` to take an opt-in Spotlight flag with the budget-safe config**

Replace the current `makeSession(context:)` body's tool-construction tail. The signature gains `includeSpotlight: Bool = false`. Final form of the method's tool section:

```swift
    private func makeSession(context: AssistantContext,
                             includeSpotlight: Bool = false) throws -> LanguageModelSession {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable:
            throw AssistantError.unavailable(
                "Apple Intelligence isn't available. Enable it in System Settings → Apple Intelligence & Siri, then try again."
            )
        @unknown default:
            throw AssistantError.unavailable("The on-device model is unavailable on this device.")
        }
        let instructions = Self.instructions(for: context)
        var tools: [any Tool] = []
        if includeSpotlight {
            // Default GuidanceLevel.complete injects a ~13k-token query manual that exceeds the
            // on-device 4,096-token window. .focused(.items) scopes guidance to our page/post
            // text domain and .compact trims output — measured to fit (C.8, #158).
            tools.append(SpotlightSearchTool(configuration: .init(
                sources: [.coreSpotlight],
                guide: .init(level: .focused(.items), format: .compact))))
        }
        if let editBridge, let contentGraph {
            tools.append(ApplyEditTool(
                bridge: editBridge,
                siteID: context.siteID,
                contextSelector: context.selectedElementSelector
            ))
            tools.append(SearchContentTool(contentGraph: contentGraph, siteID: context.siteID))
        }
        return tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)
    }
```

- [x] **Step 2: Have only the conversational path request Spotlight**

In `conversationSession(for:)`, change the `makeSession` call to opt in:

```swift
    private func conversationSession(for context: AssistantContext) throws -> LanguageModelSession {
        if let session { return session }
        let created = try makeSession(context: context, includeSpotlight: true)
        session = created
        return created
    }
```

Leave the `generate` and `generateStructured` calls to `makeSession(context:)` unchanged (they use the `includeSpotlight: false` default).

- [x] **Step 3: Ensure `import CoreSpotlight`, `supportsTools: true`, and `attachedToolNames` are correct**

These were set in `3b1ae44`; confirm they read as below (fix if not):

```swift
// near line 44, inside #if compiler(>=6.4):
import FoundationModels
import CoreSpotlight
```
```swift
// in `capabilities`:
            supportsTools: true,  // converse session always carries SpotlightSearchTool (C.8, #158)
```
```swift
    private var attachedToolNames: [String] {
        // SpotlightSearchTool is always on the converse session; the edit/search pair only when
        // their deps exist. "spotlightSearch" is a display label — the system tool exposes no name.
        var names = ["spotlightSearch"]
        if editBridge != nil && contentGraph != nil {
            names += [ApplyEditTool.toolName, SearchContentTool.toolName]
        }
        return names
    }
```

- [x] **Step 4: Refresh the `init` and `attachedToolNames` doc comments to say "conversational path"**

`init` doc comment:

```swift
    /// The multi-turn ``converse(prompt:context:)`` session attaches Apple's `SpotlightSearchTool`
    /// (budget-fit `.focused(.items)`/`.compact` config) for local RAG over indexed site content,
    /// so ``capabilities`` always advertises `supportsTools` (C.8, #158). When **both** `editBridge`
    /// and `contentGraph` are supplied, ``ApplyEditTool`` + ``SearchContentTool`` are added too. The
    /// one-shot ``generate``/``generateStructured`` paths carry no Spotlight tool, preserving their
    /// full context budget for generation.
```

`attachedToolNames` doc comment:

```swift
    /// Tool names for the `.started` event (emitted only on the `converse` path) so the chat UI can
    /// reflect what's wired. Never empty — the conversational session always carries
    /// `SpotlightSearchTool`; the edit/search pair is added only when both deps are present.
```

- [x] **Step 5: Fix the test suite for the v2 contract**

In `Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift`, confirm `onDeviceCapabilities` asserts `#expect(caps.supportsTools)` and the `spotlightMakesToolsUnconditional` test exists (both set in `3b1ae44` — keep). Add this guarded budget-fit smoke after the existing `converseEmitsLifecycleEvents` test:

```swift
    @Test("converse with the Spotlight tool attached fits the on-device budget and completes")
    func converseWithSpotlightFitsBudget() async throws {
        guard modelAvailable() else { return }
        // Regression guard for the 13k-token overflow: the default SpotlightSearchTool() guidance
        // exceeds the 4,096-token window. A no-deps assistant's converse path carries only the
        // configured Spotlight tool, so reaching .turnComplete proves the .focused/.compact guide
        // fits (C.8, #158).
        let assistant = FoundationModelAssistant()
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(
            prompt: "Say hello in one short sentence.",
            context: makeContext()
        ) {
            events.append(event)
        }
        guard case .turnComplete = events.last else {
            Issue.record("Expected .turnComplete (budget fit), got \(String(describing: events.last))")
            return
        }
    }
```

In `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift`, the `FoundationModelAssistantToolWiringTests` assertions (`supportsTools == true` in all configs; `.started` names `["spotlightSearch", ApplyEditTool.toolName, SearchContentTool.toolName]`) were updated in `3b1ae44` — confirm they still hold under v2 (they do: converse attaches Spotlight, and with both deps it adds the pair). No change expected.

- [x] **Step 6: Run the focused capability + tool-wiring tests (must pass without the model)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter "FoundationModelAssistant"
```
Expected: the capability tests (`onDeviceCapabilities`, `spotlightMakesToolsUnconditional`) and the `FoundationModelAssistantToolWiringTests` capability assertion PASS. Live model tests (`guard modelAvailable()`) pass on a host with Apple Intelligence enabled, else no-op.

- [x] **Step 7: Run the live regression checks (on this host the model IS available)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter "generateStreamsText"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . --filter "converseWithSpotlightFitsBudget"
```
Expected: BOTH PASS. `generateStreamsText` proves the one-shot path is tool-free / unbroken; `converseWithSpotlightFitsBudget` proves the configured Spotlight tool fits the budget on the converse path. If either fails with "Provided NN,NNN tokens, but the maximum allowed is 4,096", the guide config is wrong — do not proceed.

- [x] **Step 8: Commit the v2 changes as a new commit**

(The earlier `3b1ae44` and a v2 doc commit are already on the branch; this adds a follow-up commit. The branch will be squash-merged, so a clean final diff matters more than a single commit here.)

```bash
git add Sources/AnglesiteCore/FoundationModelAssistant.swift \
        Tests/AnglesiteCoreTests/FoundationModelAssistantTests.swift \
        Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "feat(intents): configure SpotlightSearchTool + scope to converse path (#158)

The conversational FoundationModelAssistant session now carries Apple's
SpotlightSearchTool (focused(.items)/compact guide — the default .complete
guide's ~13k-token manual exceeds the on-device 4,096 window), giving the
on-device model local retrieval over the Core Spotlight index that
ContentSpotlightIndexer populates. One-shot generate/generateStructured stay
tool-free to preserve their context budget. supportsTools is now true.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Full-suite regression + record the manual smoke

**Files:** No code changes. Verification + issue bookkeeping only.

- [x] **Step 1: Run the full AnglesiteCore suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path . 2>&1 | tail -20
```
Expected: no new failures in `AnglesiteCoreTests` beyond the known plugin-gated e2e tests when `ANGLESITE_PLUGIN_PATH` is unset (see CLAUDE.md). The previously-passing live model tests pass again (the one-shot paths no longer carry the oversized tool).

- [x] **Step 2: Record the Tier-3 manual smoke on the issue**

The model-actually-retrieves check needs a built app, Apple Intelligence enabled, and content propagated into the system Spotlight index — it cannot run in `swift test`. Post this on #158:

```bash
gh issue comment 158 --body "Tier-3 manual smoke (run in a real build before closing Phase C):
- [x] Open a site with several pages/posts; confirm content shows in system Spotlight.
- [x] In chat (on-device tier), ask a content-recall question (e.g. \"what did I write about X?\").
- [x] Verify the answer reflects indexed content, not a hallucination.
- [x] Confirm the .started event lists the Spotlight tool in the chat UI."
```

- [x] **Step 3: No commit** (verification + issue comment only).

---

## Self-Review

**Spec coverage:**
- Config fix (`focused(.items)`/`compact`) → Task 1 Step 1. ✓
- Conversational-path-only attach (`includeSpotlight` flag) → Task 1 Steps 1-2. ✓
- `import CoreSpotlight` → Task 1 Step 3. ✓
- `supportsTools == true` → Task 1 Step 3 + tests Step 5. ✓
- `attachedToolNames` Spotlight label → Task 1 Step 3. ✓
- Tier-1 CI-safe capability tests → Task 1 Steps 5-6. ✓
- Tier-2 budget-fit live smoke → Task 1 Steps 5, 7. ✓
- Tier-3 manual → Task 2 Step 2. ✓

**Placeholder scan:** No TBD/TODO; all code steps show full code. ✓

**Type consistency:** `makeSession(context:includeSpotlight:)`, `conversationSession(for:)`, `supportsTools`, `attachedToolNames`, `SpotlightSearchTool(configuration:)`, `ApplyEditTool.toolName`, `SearchContentTool.toolName` used consistently and match the SDK interface verified from `_CoreSpotlight_FoundationModels.swiftinterface`. ✓
