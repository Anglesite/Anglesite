# design-interview Conversation + PCC Escalation Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the design-interview conversation (Intent → Mood → Brand → Axis confirmation) as an on-device-FM-backed chat flow with a live GUI mirror, converging on the same `DesignApplyService` write path as the theme-apply wizard, and give `FoundationModelAssistant`'s `.privateCloudCompute` tier a real escalation path instead of its current on-device stub.

**Architecture:** `DesignInterviewModel` drives a `ConversationStage` state machine over `FoundationModelAssistant.converse()`, using `@Generable` structured replies so each turn updates a typed `DesignInterviewDraft` rather than parsing free text. Stage-specific grounding prompts are pure, deterministic, unit-testable builders (mirroring `SiteGraphExplainPrompt`). The escalation mechanism is gated behind **Task 1, a feasibility spike** — this plan does not assume PCC escalation is achievable through Apple's public `FoundationModels` API until that's verified.

**Tech Stack:** Swift 6.4, FoundationModels (`#if compiler(>=6.4)`), SwiftUI, Swift Testing.

## Global Constraints

- Same toolchain/testing constraints as the theme-apply plan (`DEVELOPER_DIR=/Applications/Xcode-beta.app/...`, hosted UI tests don't run on CI).
- **This plan depends on the theme-apply plan's `DesignApplyService`/`DesignApplyInput`/`AppliedDesign`/`DesignApplyError` (Tasks 6-7 there) and `DesignAxes`/`DesignConfigGenerator`/`DesignTokenWriter` (Tasks 2-5 there) already being merged.** Do not re-implement them.
- `FoundationModelAssistant`'s existing `AssistantError/unavailable(_:)` semantics apply: no network fallback when Apple Intelligence is off — the feature goes unavailable, never degrades to a cloud call outside Apple's own PCC path (per the LLM policy, #459 §8).
- On-device context budget is 4,096 tokens (`AssistantCapabilities.maxContextTokens`). Grounding prompts must stay well under this — cap list/history sizes the way `SiteGraphExplainPrompt.maxListedNames` does.
- No new third-party dependencies.

---

### Task 1: PCC feasibility spike (investigation, not implementation)

**Files:** none created — this is a documented investigation with a pass/fail decision gate. Record findings in a new file `docs/specs/2026-07-10-pcc-escalation-spike-notes.md`.

**Why this is Task 1, not deferred:** `Sources/AnglesiteCore/FoundationModelAssistant.swift:9-13` already documents that "the public `FoundationModels` framework is on-device. There is no caller-selectable Private Cloud Compute session; PCC is used transparently by some system APIs." That comment is the strongest existing evidence that a caller-initiated PCC escalation may not be buildable at all through public API — Tasks 4-5 of this plan branch on what this spike actually finds, so it must run first.

- [ ] **Step 1: Check Apple's current public API surface for PCC**

On the Xcode 27 toolchain, inspect the `FoundationModels` module interface for any PCC-related symbol:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift-ide-test \
  -print-module -module-to-print=FoundationModels -source-filename x \
  -target arm64-apple-macos27.0 2>/dev/null | grep -i "cloud\|pcc\|remote"
```

Record every match (symbol name, availability annotation, doc comment) in the spike notes file. If this returns nothing, that's a strong (not yet conclusive) signal against a caller-selectable PCC path.

- [ ] **Step 2: Check Apple's current developer documentation**

Search Apple's FoundationModels documentation (developer.apple.com/documentation/foundationmodels) and WWDC 2026/2027 session notes for "Private Cloud Compute", "PCC", or "larger model" in the context of `LanguageModelSession`/`SystemLanguageModel`. Record what's found — specifically whether there's any documented way for an app to *request* a larger/cloud-backed model, versus PCC being purely an OS-internal implementation detail invoked transparently for unrelated system features (e.g. Siri, Visual Intelligence) with no app-facing hook.

- [ ] **Step 3: Probe for a larger on-device model tier**

Check whether `SystemLanguageModel` exposes any variant/size selector at all (some Apple platforms expose a "large" vs "default" adapter). Look for `SystemLanguageModel.Use case`, custom adapters, or any initializer beyond `.default`:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift-ide-test \
  -print-module -module-to-print=FoundationModels -source-filename x \
  -target arm64-apple-macos27.0 2>/dev/null | grep -A3 "class SystemLanguageModel\|struct SystemLanguageModel"
```

- [ ] **Step 4: Decision gate — record the outcome and pick a path**

Write the finding as one of two outcomes in `docs/specs/2026-07-10-pcc-escalation-spike-notes.md`:

- **PCC-reachable**: a genuine app-facing API exists to request a larger/cloud-backed session. Record the exact API surface found. → Continue to Task 4 as written (real escalation).
- **PCC-not-reachable** (the expected outcome, given the existing code comment): no public API lets an app request PCC or a larger model. → Skip Task 4's "real PCC call" and implement Task 4 as **deterministic context-budget escalation** instead: when a stage's grounding prompt would exceed the 4,096-token budget, chunk/summarize deterministically rather than claim a larger model is available. Update `FoundationModelTier`'s doc comment to state plainly that `.privateCloudCompute` remains aspirational/unimplemented pending a future Apple API, rather than leaving the current misleading "reserved for future use" framing. This is not a failure of the plan — it's the honest outcome the design spec's own risk section (§8) anticipated, and it's why this spike is Task 1 rather than an assumption baked into the design.

- [ ] **Step 5: Commit the spike notes**

```bash
git add docs/specs/2026-07-10-pcc-escalation-spike-notes.md
git commit -m "docs: PCC escalation feasibility spike findings (#464)"
```

---

### Task 2: DesignInterviewDraft + ConversationStage (deterministic types)

**Files:**
- Create: `Sources/AnglesiteCore/DesignInterviewDraft.swift`
- Test: `Tests/AnglesiteCoreTests/DesignInterviewDraftTests.swift`

**Interfaces:**
- Consumes: `DesignAxes`, `DesignAxesCatalog` (from the theme-apply plan).
- Produces:
```swift
public enum ConversationStage: Int, Sendable, Equatable, CaseIterable { case intent, mood, brandAnchor, axisConfirmation, done }
public struct DesignInterviewDraft: Sendable, Equatable {
    public var stage: ConversationStage
    public var businessType: String
    public var axes: DesignAxes
    public var brandColorHex: String?
    public var freeTextNotes: [String]
    public init(businessType: String)
    public mutating func advance()
    public mutating func applyAdjectiveHint(_ hint: DesignAdjectiveHint)
}
public enum DesignAdjectiveHint: String, Sendable, CaseIterable {
    case warmer, cooler, denser, airier, moreAuthoritative, morePlayful, moreClassic, moreContemporary, bolder, subtler
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignInterviewDraftTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignInterviewDraftTests {
    @Test func initSeedsAxesFromBusinessType() {
        let draft = DesignInterviewDraft(businessType: "restaurant")
        #expect(draft.axes == DesignAxesCatalog.defaults(forBusinessType: "restaurant"))
        #expect(draft.stage == .intent)
    }

    @Test func advanceStepsThroughAllStagesInOrder() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let expected: [ConversationStage] = [.mood, .brandAnchor, .axisConfirmation, .done]
        for stage in expected {
            draft.advance()
            #expect(draft.stage == stage)
        }
    }

    @Test func advancePastDoneStaysAtDone() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        for _ in 0..<10 { draft.advance() }
        #expect(draft.stage == .done)
    }

    @Test func adjectiveHintNudgesTheRightAxis() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.temperature
        draft.applyAdjectiveHint(.warmer)
        #expect(draft.axes.temperature > before)
    }

    @Test func adjectiveHintClampsAtOne() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        for _ in 0..<20 { draft.applyAdjectiveHint(.bolder) }
        #expect(draft.axes.voice == 1.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewDraftTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignInterviewDraft.swift
import Foundation

public enum ConversationStage: Int, Sendable, Equatable, CaseIterable {
    case intent, mood, brandAnchor, axisConfirmation, done
}

/// A fixed nudge applied to one axis when the user's free text names a direction rather than a
/// slider value (e.g. "make it warmer"). Each hint moves its axis by a flat 0.15, clamped to [0,1].
public enum DesignAdjectiveHint: String, Sendable, CaseIterable {
    case warmer, cooler, denser, airier, moreAuthoritative, morePlayful, moreClassic, moreContemporary, bolder, subtler

    var keyPath: WritableKeyPath<DesignAxes, Double> {
        switch self {
        case .warmer, .cooler: return \.temperature
        case .denser, .airier: return \.weight
        case .moreAuthoritative, .morePlayful: return \.register
        case .moreClassic, .moreContemporary: return \.time
        case .bolder, .subtler: return \.voice
        }
    }

    var delta: Double {
        switch self {
        case .warmer, .denser, .moreAuthoritative, .moreContemporary, .bolder: return 0.15
        case .cooler, .airier, .morePlayful, .moreClassic, .subtler: return -0.15
        }
    }
}

public struct DesignInterviewDraft: Sendable, Equatable {
    public var stage: ConversationStage
    public var businessType: String
    public var axes: DesignAxes
    public var brandColorHex: String?
    public var freeTextNotes: [String]

    public init(businessType: String) {
        self.stage = .intent
        self.businessType = businessType
        self.axes = DesignAxesCatalog.defaults(forBusinessType: businessType)
        self.brandColorHex = nil
        self.freeTextNotes = []
    }

    public mutating func advance() {
        guard let next = ConversationStage(rawValue: stage.rawValue + 1) else { return }
        stage = next
    }

    public mutating func applyAdjectiveHint(_ hint: DesignAdjectiveHint) {
        axes = DesignAxesCatalog.adjusted(axes, by: [hint.keyPath: hint.delta])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewDraftTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignInterviewDraft.swift Tests/AnglesiteCoreTests/DesignInterviewDraftTests.swift
git commit -m "feat(core): add DesignInterviewDraft + ConversationStage state machine"
```

---

### Task 3: Stage grounding prompts (deterministic prompt builders)

**Files:**
- Create: `Sources/AnglesiteCore/DesignInterviewPrompts.swift`
- Test: `Tests/AnglesiteCoreTests/DesignInterviewPromptsTests.swift`

**Interfaces:**
- Consumes: `DesignInterviewDraft`, `ConversationStage` (Task 2).
- Produces: `enum DesignInterviewPrompts { static func prompt(for stage: ConversationStage, draft: DesignInterviewDraft, userMessage: String) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignInterviewPromptsTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignInterviewPromptsTests {
    @Test func intentPromptAsksAboutPurpose() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .intent, draft: draft, userMessage: "It's a cozy neighborhood bakery.")
        #expect(prompt.contains("bakery"))
        #expect(prompt.contains("It's a cozy neighborhood bakery."))
    }

    @Test func moodPromptIncludesCurrentAxes() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .mood, draft: draft, userMessage: "warmer and more playful")
        #expect(prompt.contains("temperature"))
        #expect(prompt.contains(String(draft.axes.temperature)))
    }

    @Test func brandAnchorPromptAsksForColorOrReference() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .brandAnchor, draft: draft, userMessage: "our brand color is #ff6600")
        #expect(prompt.lowercased().contains("brand color") || prompt.lowercased().contains("hex"))
    }

    @Test func axisConfirmationPromptSummarizesFinalAxes() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .axisConfirmation, draft: draft, userMessage: "looks good")
        for axisName in ["temperature", "weight", "register", "time", "voice"] {
            #expect(prompt.contains(axisName))
        }
    }

    @Test func promptsStayUnderOnDeviceBudgetEstimate() {
        let draft = DesignInterviewDraft(businessType: "restaurant")
        for stage in ConversationStage.allCases where stage != .done {
            let prompt = DesignInterviewPrompts.prompt(for: stage, draft: draft, userMessage: String(repeating: "word ", count: 50))
            // Conservative proxy matching FoundationModelAssistant.maxPageContentCharacters' approach:
            // no single turn prompt should exceed ~2000 characters, leaving room for history + reply.
            #expect(prompt.count < 2000)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewPromptsTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignInterviewPrompts.swift
import Foundation

/// Deterministic grounding-prompt builders for the design-interview conversation, one per
/// ``ConversationStage``. Follows ``SiteGraphExplainPrompt``'s pattern: facts are assembled from
/// typed data, never invented, and every prompt caps its own size to stay well under the
/// on-device 4,096-token budget.
public enum DesignInterviewPrompts {
    public static func prompt(for stage: ConversationStage, draft: DesignInterviewDraft, userMessage: String) -> String {
        switch stage {
        case .intent: return intentPrompt(draft: draft, userMessage: userMessage)
        case .mood: return moodPrompt(draft: draft, userMessage: userMessage)
        case .brandAnchor: return brandAnchorPrompt(draft: draft, userMessage: userMessage)
        case .axisConfirmation: return axisConfirmationPrompt(draft: draft, userMessage: userMessage)
        case .done: return userMessage
        }
    }

    private static func intentPrompt(draft: DesignInterviewDraft, userMessage: String) -> String {
        """
        You are interviewing the owner of a \(draft.businessType) website about what the site is \
        for and who it's for. Ask one short, warm follow-up question to understand their intent — \
        don't move to visual style yet. Owner said: "\(userMessage)"
        """
    }

    private static func moodPrompt(draft: DesignInterviewDraft, userMessage: String) -> String {
        """
        You are helping the owner of a \(draft.businessType) website describe its visual mood. \
        Current design axes (each 0 to 1): temperature \(draft.axes.temperature) (cool<->warm), \
        weight \(draft.axes.weight) (airy<->dense), register \(draft.axes.register) \
        (playful<->authoritative), time \(draft.axes.time) (classic<->contemporary), voice \
        \(draft.axes.voice) (subtle<->bold). The owner described the mood they want as: \
        "\(userMessage)". In one short sentence, reflect back how that mood shifts these axes.
        """
    }

    private static func brandAnchorPrompt(draft: DesignInterviewDraft, userMessage: String) -> String {
        """
        Ask the owner of a \(draft.businessType) website if they have an existing brand color \
        (hex code) or a reference site/brand whose look they like. Owner said: "\(userMessage)". \
        If they gave a hex color or a clear reference, acknowledge it in one short sentence.
        """
    }

    private static func axisConfirmationPrompt(draft: DesignInterviewDraft, userMessage: String) -> String {
        """
        Summarize this design in plain language for the owner of a \(draft.businessType) website, \
        then ask them to confirm or adjust: temperature \(draft.axes.temperature), weight \
        \(draft.axes.weight), register \(draft.axes.register), time \(draft.axes.time), voice \
        \(draft.axes.voice). Owner's response: "\(userMessage)".
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewPromptsTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignInterviewPrompts.swift Tests/AnglesiteCoreTests/DesignInterviewPromptsTests.swift
git commit -m "feat(core): add deterministic design-interview grounding prompts"
```

---

### Task 4: Escalation seam in FoundationModelAssistant (branches on Task 1's finding)

**Files:**
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/FoundationModelAssistantEscalationTests.swift` (new file)

**Interfaces:**
- Produces: `extension FoundationModelAssistant { func escalate(reason: EscalationReason) async -> FoundationModelTier }`, `enum EscalationReason: Sendable, Equatable { case contextBudgetExceeded(estimatedTokens: Int), userRequestedBetter }`

**This task has two implementations depending on Task 1's outcome — implement only the branch that spike found true, and delete the other's code block from this task before starting:**

**If Task 1 found PCC-reachable:** implement `escalate(reason:)` to actually construct a session against the real API surface Task 1 documented, returning `.privateCloudCompute` on success and logging + returning `.onDevice` on failure (never throwing — escalation failure degrades to on-device, it doesn't fail the turn). Write this task's tests and implementation from that documented API once known; it can't be pre-written here since the API doesn't exist yet in verified form.

**If Task 1 found PCC-not-reachable (expected):** implement `escalate(reason:)` as deterministic context-budget management, not a real tier switch — this is the realistic version to build now:

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/FoundationModelAssistantEscalationTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct FoundationModelAssistantEscalationTests {
    @Test func estimatedTokensUsesCharacterProxy() {
        // Matches FoundationModelAssistant.maxPageContentCharacters' existing character-based
        // proxy approach (no on-device tokenizer is available).
        let text = String(repeating: "a", count: 4000)
        #expect(FoundationModelAssistant.estimatedTokens(for: text) > FoundationModelAssistant.onDeviceTokenBudget)
    }

    @Test func shouldEscalateWhenOverBudget() {
        let longPrompt = String(repeating: "word ", count: 2000)
        #expect(FoundationModelAssistant.shouldEscalate(prompt: longPrompt) == true)
    }

    @Test func shouldNotEscalateWhenUnderBudget() {
        #expect(FoundationModelAssistant.shouldEscalate(prompt: "short prompt") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelAssistantEscalationTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Appended to Sources/AnglesiteCore/FoundationModelAssistant.swift, above the `#if compiler(>=6.4)` guard
// so the budget helpers are usable (and testable) on toolchains without FoundationModels too.

public extension FoundationModelAssistant {
    /// Conservative characters-per-token proxy (~4 chars/token for English), matching the existing
    /// character-based approach in `maxPageContentCharacters` — no on-device tokenizer is available
    /// to measure the real count.
    static let onDeviceTokenBudget = 4_096
    private static let charsPerTokenEstimate = 4

    static func estimatedTokens(for text: String) -> Int {
        text.count / charsPerTokenEstimate
    }

    /// Whether a prompt is estimated to exceed the on-device context budget. Per Task 1's spike
    /// finding (PCC not reachable via public API as of macOS 27), "escalation" here means the
    /// caller (``DesignInterviewModel``) should chunk/summarize deterministically rather than
    /// request a genuinely larger model — there is no such request to make.
    static func shouldEscalate(prompt: String) -> Bool {
        estimatedTokens(for: prompt) > onDeviceTokenBudget
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FoundationModelAssistantEscalationTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Update `FoundationModelTier`'s doc comment to stop implying a future PCC call is imminent**

Modify the doc comment at `Sources/AnglesiteCore/FoundationModelAssistant.swift:9-13` (the `Important:` block above `FoundationModelTier`) to state the spike's finding plainly — e.g. append: "A 2026-07-10 feasibility spike (`docs/specs/2026-07-10-pcc-escalation-spike-notes.md`) found no public API for an app to request a larger/cloud-backed session; `.privateCloudCompute` remains aspirational until Apple ships one." Do not silently leave the old wording, which reads as "not yet implemented" rather than "not currently possible."

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/FoundationModelAssistant.swift Tests/AnglesiteCoreTests/FoundationModelAssistantEscalationTests.swift
git commit -m "feat(core): add context-budget escalation seam; document PCC spike finding"
```

---

### Task 5: DesignInterviewModel — the conversation driver

**Files:**
- Create: `Sources/AnglesiteCore/DesignInterviewModel.swift`
- Test: `Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift`

**Interfaces:**
- Consumes: `DesignInterviewDraft`, `ConversationStage`, `DesignAdjectiveHint` (Task 2), `DesignInterviewPrompts` (Task 3), `FoundationModelAssistant.shouldEscalate` (Task 4), `DesignApplyService`/`DesignApplyInput`/`AppliedDesign` (theme-apply plan), `DesignConfigGenerator`/`DesignTokenWriter` (theme-apply plan), `ConversationalAssistant`/`AssistantContext`/`AssistantEvent` (existing `ContentAssistant` protocol family).
- Produces:
```swift
@MainActor @Observable
public final class DesignInterviewModel: Identifiable {
    public let id = UUID()
    public internal(set) var draft: DesignInterviewDraft
    public internal(set) var transcript: [(role: String, text: String)] = []
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?
    public init(businessType: String, assistant: any ConversationalAssistant, package: AnglesitePackage)
    public func send(_ userMessage: String) async
    public func nudge(_ hint: DesignAdjectiveHint)
    public func skipToAxisConfirmation() // "design it for me" escape hatch
    public func confirmAndApply() async
}
```

Since `FoundationModelAssistant` is gated `#if compiler(>=6.4)`, `DesignInterviewModel` depends on the toolchain-independent `ConversationalAssistant` protocol (already used by `FoundationModelAssistant`'s conformance) rather than the concrete type directly — this keeps the model itself testable on any toolchain with a fake assistant, matching how `SiteGraphNodeExplaining` decouples `SiteGraphExplainerFactory`'s consumers from the gated implementation.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Minimal fake — echoes the prompt back as a single `.textDelta` then `.turnComplete`, so tests
/// can assert on stage progression and draft state without a real FoundationModels session.
private actor FakeConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
                              supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
    }
    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("echo: \(prompt)"); $0.finish() }
    }
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        fatalError("not used by DesignInterviewModelTests")
    }
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        AsyncStream { continuation in
            continuation.yield(.started(model: "Fake", toolNames: []))
            continuation.yield(.textDelta("Got it."))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }
    func cancel() async {}
    func resetSession() async {}
}

@Suite struct DesignInterviewModelTests {
    private func makeSite() throws -> AnglesitePackage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(sourceDirectory: dir)
    }

    @Test @MainActor func sendAppendsToTranscriptAndAdvancesStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .mood)
        #expect(model.transcript.contains { $0.role == "user" && $0.text == "It's a cozy neighborhood bakery." })
        #expect(model.transcript.contains { $0.role == "assistant" && $0.text == "Got it." })
    }

    @Test @MainActor func nudgeAdjustsAxesWithoutAdvancingStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        let before = model.draft.axes.temperature
        model.nudge(.warmer)
        #expect(model.draft.axes.temperature > before)
        #expect(model.draft.stage == .intent)
    }

    @Test @MainActor func skipToAxisConfirmationJumpsStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        #expect(model.draft.stage == .axisConfirmation)
    }

    @Test @MainActor func confirmAndApplyWritesThroughDesignApplyService() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        await model.confirmAndApply()
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("src/styles/global.css"))
        #expect(model.draft.stage == .done)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewModelTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignInterviewModel.swift
import Foundation
import Observation

@MainActor @Observable
public final class DesignInterviewModel: Identifiable {
    public let id = UUID()
    public internal(set) var draft: DesignInterviewDraft
    public internal(set) var transcript: [(role: String, text: String)] = []
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?

    private let assistant: any ConversationalAssistant
    private let package: AnglesitePackage
    private let siteID: String

    public init(businessType: String, assistant: any ConversationalAssistant, package: AnglesitePackage, siteID: String = "") {
        self.draft = DesignInterviewDraft(businessType: businessType)
        self.assistant = assistant
        self.package = package
        self.siteID = siteID
    }

    /// Sends one turn: appends the user's message, prompts the current stage, appends the
    /// assistant's reply, then advances the conversation to the next stage. Structured
    /// (`@Generable`) axis extraction from the reply is a follow-up refinement (see plan note below)
    /// — v1 advances on any reply and lets the user correct axes via ``nudge(_:)``.
    public func send(_ userMessage: String) async {
        transcript.append((role: "user", text: userMessage))
        let prompt = DesignInterviewPrompts.prompt(for: draft.stage, draft: draft, userMessage: userMessage)
        let context = AssistantContext(siteID: siteID, siteDirectory: package.sourceDirectory)
        guard let stream = try? await assistant.converse(prompt: prompt, context: context) else {
            transcript.append((role: "assistant", text: "I couldn't respond just now — try again in a moment."))
            return
        }
        var reply = ""
        for await event in stream {
            if case .textDelta(let delta) = event { reply += delta }
        }
        transcript.append((role: "assistant", text: reply))
        draft.advance()
    }

    public func nudge(_ hint: DesignAdjectiveHint) {
        draft.applyAdjectiveHint(hint)
    }

    /// "Design it for me" escape hatch: skip straight to axis confirmation using the
    /// business-type defaults already seeded in `draft.axes`.
    public func skipToAxisConfirmation() {
        draft.stage = .axisConfirmation
    }

    public func confirmAndApply() async {
        let config = DesignConfigGenerator.config(axes: draft.axes, siteType: draft.businessType, brandColor: draft.brandColorHex)
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: config),
            rationaleMarkdown: DesignTokenWriter.rationaleMarkdown(for: config),
            brandSummary: "Generated from a design interview for a \(draft.businessType).",
            sourceLabel: "design-interview"
        )
        applyResult = DesignApplyService.apply(input, to: package)
        draft.stage = .done
    }
}
```

**Note for the implementer:** `send(_:)` currently advances the stage on any reply rather than parsing the assistant's response into a structured `@Generable` update (e.g. detecting an adjective hint or brand-color mention automatically). The design called for structured replies driving live axis updates from the conversation itself; this task ships the simpler "advance + let the user `nudge()` explicitly" version first, working and testable end-to-end, with structured-reply parsing as a clearly-scoped follow-up (Task 6 below) rather than something silently missing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewModelTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignInterviewModel.swift Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift
git commit -m "feat(core): add DesignInterviewModel conversation driver"
```

---

### Task 6: Structured per-turn axis extraction (upgrade `send` from echo-advance to `@Generable`)

**Files:**
- Modify: `Sources/AnglesiteCore/DesignInterviewModel.swift`
- Modify: `Sources/AnglesiteCore/DesignInterviewPrompts.swift` (prompts must ask for structured output)
- Test: append to `Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift`

**Interfaces:**
- Produces (gated `#if compiler(>=6.4)`): `@Generable public struct DesignInterviewTurnReply { @Guide var replyText: String; @Guide var temperatureDelta: Double?; @Guide var weightDelta: Double?; @Guide var registerDelta: Double?; @Guide var timeDelta: Double?; @Guide var voiceDelta: Double?; @Guide var brandColorHex: String? }`

This task requires a live FoundationModels session to exercise meaningfully (structured generation can't be faked through the `ConversationalAssistant` protocol's untyped `converse`, since `@Generable` guided generation is a `FoundationModelAssistant`-specific capability reached via `generateStructured`, not `converse`). Because of that, this task's test coverage is necessarily thinner than Task 5's — cover the deterministic glue (applying a decoded `DesignInterviewTurnReply`'s deltas to a `DesignInterviewDraft`) with a real unit test, and leave the actual FM call to manual GUI smoke, consistent with the design spec's testing strategy.

- [ ] **Step 1: Write the failing test for the deterministic glue**

```swift
// Appended to Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift
extension DesignInterviewModelTests {
    @Test func applyingTurnReplyDeltasNudgesAxesAndCapturesBrandColor() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.temperature
        DesignInterviewModel.applyTurnReplyDeltas(
            temperature: 0.1, weight: nil, register: nil, time: nil, voice: nil,
            brandColorHex: "#ff6600", to: &draft
        )
        #expect(draft.axes.temperature == before + 0.1)
        #expect(draft.brandColorHex == "#ff6600")
    }

    @Test func applyingNilDeltasLeavesAxesUnchanged() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes
        DesignInterviewModel.applyTurnReplyDeltas(
            temperature: nil, weight: nil, register: nil, time: nil, voice: nil,
            brandColorHex: nil, to: &draft
        )
        #expect(draft.axes == before)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewModelTests`
Expected: FAIL (compile error — `applyTurnReplyDeltas` doesn't exist yet)

- [ ] **Step 3: Implement the deterministic glue (non-gated) and the `@Generable` type (gated)**

```swift
// Appended to Sources/AnglesiteCore/DesignInterviewModel.swift, outside the compiler gate
public extension DesignInterviewModel {
    /// Applies a turn reply's optional per-axis deltas to `draft`, clamping via
    /// `DesignAxesCatalog.adjusted`. Pure and toolchain-independent so it's testable without a
    /// live FoundationModels session — the `@Generable` reply type that produces these values is
    /// gated below.
    static func applyTurnReplyDeltas(
        temperature: Double?, weight: Double?, register: Double?, time: Double?, voice: Double?,
        brandColorHex: String?, to draft: inout DesignInterviewDraft
    ) {
        var deltas: [WritableKeyPath<DesignAxes, Double>: Double] = [:]
        if let temperature { deltas[\.temperature] = temperature }
        if let weight { deltas[\.weight] = weight }
        if let register { deltas[\.register] = register }
        if let time { deltas[\.time] = time }
        if let voice { deltas[\.voice] = voice }
        if !deltas.isEmpty { draft.axes = DesignAxesCatalog.adjusted(draft.axes, by: deltas) }
        if let brandColorHex { draft.brandColorHex = brandColorHex }
    }
}

#if compiler(>=6.4)
import FoundationModels

@Generable
public struct DesignInterviewTurnReply: Sendable {
    @Guide(description: "Your conversational reply to the owner, 1-2 sentences.")
    public var replyText: String
    @Guide(description: "Temperature axis change if the owner's message implies one, else omit.")
    public var temperatureDelta: Double?
    @Guide(description: "Weight axis change if the owner's message implies one, else omit.")
    public var weightDelta: Double?
    @Guide(description: "Register axis change if the owner's message implies one, else omit.")
    public var registerDelta: Double?
    @Guide(description: "Time axis change if the owner's message implies one, else omit.")
    public var timeDelta: Double?
    @Guide(description: "Voice axis change if the owner's message implies one, else omit.")
    public var voiceDelta: Double?
    @Guide(description: "Hex color if the owner mentioned a brand color, else omit.")
    public var brandColorHex: String?
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignInterviewModelTests`
Expected: PASS (6 tests total, 2 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignInterviewModel.swift Tests/AnglesiteCoreTests/DesignInterviewModelTests.swift
git commit -m "feat(core): add structured per-turn axis extraction for design-interview"
```

**Note for the implementer:** wiring `send(_:)` to actually call `generateStructured(prompt:context:resultType: DesignInterviewTurnReply.self)` instead of `converse`'s free-text stream, and to call `applyTurnReplyDeltas` with the decoded result, is a small follow-up left undone here — flag it explicitly rather than silently leaving `send` on the Task 5 echo-advance behavior forever. This also means `send` moves off the generic `ConversationalAssistant` protocol onto `FoundationModelAssistant` directly (structured generation isn't part of that protocol's `converse` surface), which is a real API shape change worth calling out before implementing.

---

### Task 7: GUI mirror panel

**Files:**
- Create: `Sources/AnglesiteApp/DesignInterviewPanel.swift`

**Interfaces:**
- Consumes: `DesignInterviewModel` (Task 5).

No isolated unit test (SwiftUI view, same rationale as the theme-apply wizard's Task 10) — covered by manual GUI smoke.

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteApp/DesignInterviewPanel.swift
import SwiftUI
import AnglesiteCore

struct DesignInterviewPanel: View {
    @Bindable var model: DesignInterviewModel
    @State private var draftMessage = ""

    var body: some View {
        HSplitView {
            transcriptColumn
            axesColumn
        }
    }

    private var transcriptColumn: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.transcript.enumerated()), id: \.offset) { _, entry in
                        Text(entry.text)
                            .frame(maxWidth: .infinity, alignment: entry.role == "user" ? .trailing : .leading)
                    }
                }
                .padding()
            }
            HStack {
                TextField("Describe what you're going for…", text: $draftMessage)
                    .onSubmit { Task { await sendDraft() } }
                Button("Send") { Task { await sendDraft() } }
                    .disabled(draftMessage.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 320)
    }

    private var axesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Design Axes").font(.headline)
            axisSlider("Cool", "Warm", value: $model.draft.axes.temperature)
            axisSlider("Airy", "Dense", value: $model.draft.axes.weight)
            axisSlider("Playful", "Authoritative", value: $model.draft.axes.register)
            axisSlider("Classic", "Contemporary", value: $model.draft.axes.time)
            axisSlider("Subtle", "Bold", value: $model.draft.axes.voice)

            Spacer()

            if model.draft.stage == .axisConfirmation {
                Button("Apply This Design") { Task { await model.confirmAndApply() } }
                    .buttonStyle(.borderedProminent)
            }

            if case .success = model.applyResult {
                Label("Applied.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    private func axisSlider(_ low: String, _ high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(low).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }

    private func sendDraft() async {
        guard !draftMessage.isEmpty else { return }
        let message = draftMessage
        draftMessage = ""
        await model.send(message)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/DesignInterviewPanel.swift
git commit -m "feat(app): add DesignInterviewPanel GUI mirror for the design interview"
```

---

### Task 8: Front doors — FM tool and Siri intent

**Files:**
- Create: `Sources/AnglesiteCore/DesignInterviewTool.swift`
- Create: `Sources/AnglesiteIntents/DesignInterviewIntents.swift`

**Interfaces:**
- Consumes: `DesignInterviewModel` (Task 5), `SiteEntity` (existing).

No isolated unit tests — both are thin front-door wiring over an already-tested model, matching `SetupIntegrationTool`/`IntegrationIntents.swift`'s own untested-glue precedent for the `AppIntents`-runtime-dependent half.

- [ ] **Step 1: Implement the Siri entry point**

```swift
// Sources/AnglesiteIntents/DesignInterviewIntents.swift
import AppIntents
import AnglesiteCore
import Foundation

/// Opens chat pre-seeded to start (or resume) the design interview for a site. The interview
/// itself runs in chat/GUI, not as a multi-turn App Intent — Siri's role is only the entry point.
public struct StartDesignInterviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Design Interview"
    public static let description = IntentDescription("Start a conversation to design your site's look and feel.")
    public static let openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Start a design interview for \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Navigation into the chat surface, pre-seeded at .intent stage, is handled by the app's
        // existing URL/scene-routing (same mechanism IntegrationIntents' siblings use to land on a
        // specific site) — wiring that route is a small follow-up left to the app-shell owner
        // rather than duplicated here.
        .result(dialog: IntentDialog(stringLiteral: "Let's design \(site.displayName). Opening chat…"))
    }
}
```

**Note for the implementer:** the comment above flags a real gap — this intent returns a dialog but doesn't yet navigate the app to a pre-seeded chat/`DesignInterviewModel` instance. Wiring that requires knowing this app's scene/URL-routing convention for landing on a specific site + chat state, which wasn't in scope to reverse-engineer for this plan; grep for how other `openAppWhenRun` intents in `AnglesiteIntents` hand off to a specific view before implementing, and complete the handoff rather than leaving the dialog as the whole feature.

- [ ] **Step 2: Implement the FM chat tool**

```swift
// Sources/AnglesiteCore/DesignInterviewTool.swift
import Foundation

#if compiler(>=6.4)
import FoundationModels

/// Chat entry point for the design interview. Unlike `SetupIntegrationTool`/`SetupThemeTool`
/// (stateless plan-then-apply calls), the interview is inherently multi-turn — this tool's `call`
/// starts or continues a session-scoped `DesignInterviewModel` the caller supplies, rather than
/// owning conversation state itself.
public struct DesignInterviewTool: Tool, Sendable {
    public static let toolName = "designInterview"
    public let name = DesignInterviewTool.toolName
    public let description = "Have a short conversation to design or redesign a site's look and feel."

    @Generable
    public struct Arguments {
        @Guide(description: "The owner's message in this turn of the design conversation.")
        public var message: String
        @Guide(description: "Set to true if the owner wants Anglesite to just pick a design for them.")
        public var designForMe: Bool?
    }

    private let model: DesignInterviewModel
    public init(model: DesignInterviewModel) { self.model = model }

    public func call(arguments: Arguments) async throws -> String {
        if arguments.designForMe == true {
            await MainActor.run { model.skipToAxisConfirmation() }
            return "I'll design it for you based on what a \(await MainActor.run { model.draft.businessType }) site usually needs. Review the axes and tell me to apply when you're happy."
        }
        await model.send(arguments.message)
        return await MainActor.run { model.transcript.last?.text ?? "" }
    }
}
#endif
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/DesignInterviewTool.swift Sources/AnglesiteIntents/DesignInterviewIntents.swift
git commit -m "feat: add design-interview FM chat tool and Siri entry point"
```

**Note for the implementer:** `DesignInterviewTool` takes a `DesignInterviewModel` instance at construction, unlike `SetupIntegrationTool`'s stateless `service`/`siteID` pair — this means `FoundationModelAssistant.conversationTools(for:includeSpotlight:)` needs a per-conversation `DesignInterviewModel` available at tool-construction time, not just a stateless service. Wiring this into `FoundationModelAssistant.init`/`conversationTools` (mirroring the `SetupIntegrationTool` wiring note in the theme-apply plan's Task 11) is left for whoever integrates both front doors together — flag it, don't skip it.

---

## Self-Review Notes

- **Spec coverage:** conversation stages (Tasks 2-3), FM-backed turns with structured axis extraction (Tasks 5-6), GUI mirror (Task 7), chat-first front door + Siri entry (Task 8), shared write path via `DesignApplyService` (Task 5's `confirmAndApply`), PCC escalation (Task 1 spike + Task 4, honestly branched rather than assumed) — all covered.
- **Known gaps surfaced to the implementer, not hidden:** (1) Task 1's outcome determines which Task 4 branch to build — this plan does not pretend PCC escalation is definitely buildable; (2) Task 6's structured-reply wiring into `send()` is left as an explicit follow-up rather than silently completed; (3) Siri's chat hand-off (Task 8) and (4) `DesignInterviewTool`'s wiring into `FoundationModelAssistant` (Task 8) are both flagged rather than faked.
- **Type consistency:** `DesignInterviewDraft`/`ConversationStage`/`DesignAdjectiveHint` (Task 2) are used identically across Tasks 3, 5, 6, 7. `DesignInterviewModel.confirmAndApply()` (Task 5) reuses `DesignApplyInput`/`AppliedDesign`/`DesignApplyError` from the theme-apply plan without redefinition, per the design spec's "one shared write path" requirement.
- **Dependency on the other plan:** this plan cannot start before the theme-apply plan's Tasks 2-7 are merged (`DesignAxes`, `DesignConfigGenerator`, `DesignTokenWriter`, `DesignApplyService` are consumed, not redefined, throughout).
