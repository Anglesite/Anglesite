# WYSIWYG AI Services — Writing Help (PR 2 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite/tighten/tone writing help on WYSIWYG text selections, with two front-doors — an
in-canvas selection toolbar (preview → Accept/Discard) and a `rewriteBlock` chat tool (same
preview-then-apply semantics) — every accepted result landing as one ordinary `editText` op.

**Architecture:** A new host-side `WritingHelpAssisting` (Core, FM-backed) takes plain text + a
natural-language instruction and returns rewritten text or a graceful unavailable message. A new
dedicated request/reply pair on the existing native-host bridge (there is no generic RPC to reuse
— confirmed by inspection) carries `{text, instruction}` from a new JS `SelectionToolbar`
component to this assistant and back. Accept mutates the live contentEditable DOM directly (the
same technique the existing format-toggle helpers already use) and reuses the existing
`runsFromElement` serializer to build the `editText` op — no new run-splicing logic. The chat
tool reaches the same assistant through a new small `WYSIWYGBlockTextAccess` protocol that
`WYSIWYGCanvasController` conforms to and that threads through the existing
`AssistantSessionAssembler` → `SiteAssistantSessionFactory` → `FoundationModelAssistant` chain the
same lazy-capture way `preview.mcpClient` already does.

**Tech Stack:** Swift 6.4 / Xcode 27 (FoundationModels guided generation), TypeScript / vitest
(JS engine), Swift Testing (`AnglesiteCoreTests`, `AnglesiteBridgeCoreTests`), Playwright
(live-selection e2e goldens — this package's established split for anything DOM-`Selection`-
dependent, since jsdom has no real text-selection behavior to verify against).

**Spec:** [`docs/superpowers/specs/2026-09-02-wysiwyg-ai-services-design.md`](../specs/2026-09-02-wysiwyg-ai-services-design.md)
§4 (writing help only — §3 alt-text is PR 1, [#1793](https://github.com/Anglesite/Anglesite/pull/1793),
not yet merged; §5 block-type suggestions is PR 3, not started). Tracking issue:
[#1227](https://github.com/Anglesite/Anglesite/issues/1227), part of epic
[#1221](https://github.com/Anglesite/Anglesite/issues/1221).

## Global Constraints

- **This PR does NOT close #1227.** Commits reference it without a closing keyword
  (`feat(#1227): ...`, never `fix`/`close`/`resolve`) — PR 3 is the one that closes the tracking
  issue, per `CONTRIBUTING.md`'s multi-PR tracking-issue guidance (this exact epic hit the
  auto-close failure mode once already — see PR 1's final review).
- **One unified instruction API, not three typed actions.** The design doc describes the
  toolbar's three fixed buttons (Rewrite/Tighten/Tone-preset) and the chat tool's free-form
  instruction as parallel front-doors to "the same preview-then-apply semantics." Rather than
  model three enum cases *and* a separate free-text path, `WritingHelpAssisting.rewrite` takes
  one `instruction: String` — the toolbar's three buttons and tone-preset menu each construct
  their own canned instruction string client-side (JS); the chat tool passes the model's own
  free-form instruction straight through. One Core method, one wire shape (`{text, instruction}`),
  no action enum. This is a deliberate simplification over the design doc's implied per-action
  typing, not a missed requirement — noted here so a reviewer doesn't flag it as a gap.
- **`generateStructured`, not raw `generate`.** The design doc says "one `ContentAssistant.generate`
  call"; there is no existing helper anywhere in this codebase for collecting `generate`'s
  `AsyncThrowingStream<String, Error>` into a single `String` (confirmed by inspection — every
  `.generate(` call site forwards the stream for incremental UI consumption instead), and every
  other one-shot FM feature (`CopyEditAuditor`, `AltTextGenerator`) uses
  `generateStructured(prompt:context:resultType:)`. `WritingHelpAssisting` follows that
  established idiom with a new `GeneratedRewrite` `@Generable` type instead of introducing the
  first bare-stream-collector in the app.
- **No positional run-splicing.** `editText` carries the block's entire new/previous `runs`
  arrays; `RichTextRun` has no character offsets. Accept does **not** manually splice a rewritten
  span into a runs array — it mutates the live contentEditable DOM directly (`Range.deleteContents()`
  + `Range.insertNode()`, the same primitive `wrapRange`/`toggleInlineFormat` already use in
  `rich-text.ts`), then re-serializes with the existing `runsFromElement()` helper. This reuses
  proven code instead of adding new run-manipulation logic.
- **Accept replaces the selected span's formatting.** A rewrite is model-generated plain text —
  it does not attempt to preserve bold/italic/link spans that existed *within* the selected
  range (text outside the selection, in the rest of the block, is untouched). This is an accepted
  v1 limitation: reformatting after a rewrite is a manual follow-up action, and Undo reverts the
  whole thing in one step if the loss matters to the owner.
- **No availability pre-check; degrade on request.** The toolbar and chat tool don't probe FM
  availability before showing themselves — a request that hits an unavailable model returns
  `WritingHelpOutcome.unavailable(message)`, shown inline (toolbar: replaces the preview area;
  chat: the tool's returned string). Matches how PR 1's alt-text proposal degrades (attempt, then
  explain) rather than adding a separate availability-probe round trip.
- **Toolchain gate:** `WritingHelpAssisting`'s FM-backed implementation and `GeneratedRewrite`
  wrap `#if compiler(>=6.4) && canImport(FoundationModels)`, matching every other FM-backed Core
  type. The protocol itself, `WYSIWYGOpsDispatcher`'s new case, and `WYSIWYGBlockTextAccess` are
  **not** gated (plain Swift, no FoundationModels dependency) — matching `ContentAssistant`'s own
  split between an ungated protocol and a gated conformance.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`) in `Tests/AnglesiteCoreTests/`
  and `Tests/AnglesiteBridgeCoreTests/`; vitest (`describe`/`it`/`expect`) in
  `JS/wysiwyg-engine/test/`. Run Swift suites via
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter <Suite>`
  (machine-scoped lock — see `CONTRIBUTING.md` ▸ Testing). Run JS suites via `npm test` from
  `JS/wysiwyg-engine/` (`npm run lint && npm run typecheck && npm test` before pushing, per
  `CONTRIBUTING.md`). **Live-`Selection`-dependent behavior is not unit-tested in jsdom** —
  this package's established split (see `toggleInlineFormat`'s own doc comment) defers that to
  Playwright e2e goldens in `JS/wysiwyg-engine/e2e/`; Task 6 follows this split explicitly.
- **Worktree:** this plan executes in `.claude/worktrees/issue-1227-pr2` on branch
  `claude/issue-1227-pr2-writing-help`, forked fresh from `origin/main` (PR 1's alt-text code is
  **not** present here — only the design spec doc was carried over as an identical docs commit).
  Run `xcodegen generate` before any app-target build; `scripts/build-app.sh` does this for you.
  `ANGLESITE_SIDECAR_SRC` should point at `../anglesite` (already set for this session).
- **Commits:** conventional commits, one per task, ending with
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

---

## Task 1: `WritingHelpAssisting` — the FM-backed rewrite core

**Files:**
- Create: `Sources/AnglesiteCore/WritingHelpAssistant.swift`
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift` (append `GeneratedRewrite` before the
  final `#endif`)
- Test: `Tests/AnglesiteCoreTests/WritingHelpAssistantTests.swift`

**Interfaces:**
- Consumes: `ContentAssistantFactory.make(tier:) -> (any ContentAssistant)?` (existing),
  `ContentAssistant.generateStructured(prompt:context:resultType:)` (existing, `#if compiler(>=6.4)`),
  `AssistantContext.init(siteID:siteDirectory:)` (existing), `BrandVoiceGuidance.preamble(conventions:businessType:) -> String?`
  (existing, `BrandVoiceGuidance.swift:9`).
- Produces: `WritingHelpOutcome { case rewritten(String); case unavailable(String) }`,
  `Equatable, Sendable` (non-gated); `WritingHelpAssisting: Sendable` protocol with
  `func rewrite(text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL) async -> WritingHelpOutcome`
  (non-gated); `WritingHelpAssistantFactory.makeDefault() -> (any WritingHelpAssisting)?` (`nil`
  below Xcode 27, pattern: `CopyEditAuditorFactory`); `WritingHelpPrompt.build(instruction:text:preamble:) -> String`
  (pure, non-gated, unit-tested directly).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/WritingHelpAssistantTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WritingHelpPrompt")
struct WritingHelpPromptTests {
    @Test("prompt contains the instruction, the text, and a verbatim-output directive")
    func promptContainsCoreParts() {
        let p = WritingHelpPrompt.build(
            instruction: "Make this noticeably shorter while keeping the essential meaning.",
            text: "We are so excited to bring you our brand new product line.",
            preamble: nil)
        #expect(p.contains("Make this noticeably shorter"))
        #expect(p.contains("We are so excited to bring you our brand new product line."))
        #expect(p.contains("only the rewritten text"))
    }

    @Test("preamble, when present, is prefixed ahead of the instruction")
    func preambleIsPrefixed() {
        let p = WritingHelpPrompt.build(
            instruction: "Rewrite this to be clearer.", text: "hello",
            preamble: "Match this site's voice:\nWrite in a warm tone.")
        #expect(p.hasPrefix("Match this site's voice:"))
        let preambleRange = p.range(of: "Write in a warm tone.")!
        let instructionRange = p.range(of: "Rewrite this to be clearer.")!
        #expect(preambleRange.lowerBound < instructionRange.lowerBound)
    }
}

// Gated like the type under test — `WritingHelpAssisting`'s default implementation references
// `GeneratedRewrite` (`@Generable`, Xcode-27 only). The logic here is model-free where possible
// (prompt building above); the assistant itself is exercised through a `ContentAssistant` fake.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("FoundationModelWritingHelpAssistant")
struct FoundationModelWritingHelpAssistantTests {
    private struct FakeAssistant: ContentAssistant {
        var structuredResult: Result<GeneratedRewrite, Error>
        var capabilities: AssistantCapabilities {
            AssistantCapabilities(
                supportsStreaming: false, supportsStructuredOutput: true, supportsVision: false,
                supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
        }
        func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func generateStructured<T: Generable & Sendable>(
            prompt: String, context: AssistantContext, resultType: T.Type
        ) async throws -> T {
            switch structuredResult {
            case .success(let value):
                guard let typed = value as? T else { fatalError("unexpected resultType in test fake") }
                return typed
            case .failure(let error):
                throw error
            }
        }
    }

    @Test("returns .rewritten with the model's text on success")
    func returnsRewrittenOnSuccess() async {
        let assistant = FoundationModelWritingHelpAssistant(
            assistantFactory: { FakeAssistant(structuredResult: .success(GeneratedRewrite(rewrittenText: "Shorter version."))) })
        let outcome = await assistant.rewrite(
            text: "A much longer original sentence.", instruction: "Tighten this.",
            preamble: nil, siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        #expect(outcome == .rewritten("Shorter version."))
    }

    @Test("returns .unavailable with a clear message when the assistant factory yields nil")
    func returnsUnavailableWhenNoAssistant() async {
        let assistant = FoundationModelWritingHelpAssistant(assistantFactory: { nil })
        let outcome = await assistant.rewrite(
            text: "x", instruction: "y", preamble: nil, siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        guard case .unavailable(let message) = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
        #expect(message.contains("Apple Intelligence") || message.contains("available"))
    }

    @Test("returns .unavailable, not a thrown error, when generateStructured fails")
    func returnsUnavailableOnGenerationFailure() async {
        struct Boom: Error {}
        let assistant = FoundationModelWritingHelpAssistant(
            assistantFactory: { FakeAssistant(structuredResult: .failure(Boom())) })
        let outcome = await assistant.rewrite(
            text: "x", instruction: "y", preamble: nil, siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter "WritingHelpPromptTests|FoundationModelWritingHelpAssistantTests"`
Expected: FAIL — cannot find `WritingHelpPrompt` / `WritingHelpOutcome` / `FoundationModelWritingHelpAssistant` in scope.

- [ ] **Step 3: Add `GeneratedRewrite` to `GenerableTypes.swift`**

In `Sources/AnglesiteCore/GenerableTypes.swift`, immediately before the file's final `#endif`,
add:

```swift
/// On-device guided-generation result for writing help — rewrite/tighten/tone (#1227 PR 2). One
/// call per request; the caller's instruction (canned per canvas-toolbar action, or free-form
/// from the `rewriteBlock` chat tool) is folded into the prompt, not this type.
@Generable
public struct GeneratedRewrite: Equatable, Sendable {
    /// The rewritten text only — no preamble, no surrounding quotes, no explanation of what changed.
    @Guide(description: "The rewritten text only. No preamble, no quotes, no explanation — just the replacement text.")
    public var rewrittenText: String
}
```

- [ ] **Step 4: Implement**

```swift
// Sources/AnglesiteCore/WritingHelpAssistant.swift
import Foundation

/// Result of a writing-help request (#1227 PR 2) — never throws to its caller. `.unavailable`
/// covers every failure mode (no FM on this Mac, a generation error) with one owner-facing
/// message, matching PR 1's alt-text "silent degrade, never surface a raw error" convention.
public enum WritingHelpOutcome: Equatable, Sendable {
    case rewritten(String)
    case unavailable(String)
}

/// Rewrites `text` per a natural-language `instruction` — the shared core behind both the canvas
/// selection toolbar (canned instructions per button) and the `rewriteBlock` chat tool (free-form
/// instruction). One method, no action enum (see plan Global Constraints).
public protocol WritingHelpAssisting: Sendable {
    /// `preamble` is a `BrandVoiceGuidance`-built voice preamble, prepended verbatim when present.
    func rewrite(
        text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL
    ) async -> WritingHelpOutcome
}

/// `nil` below the Xcode-27 toolchain — callers hide/disable the feature (pattern:
/// `CopyEditAuditorFactory`).
public enum WritingHelpAssistantFactory {
    public static func makeDefault() -> (any WritingHelpAssisting)? {
        #if compiler(>=6.4) && canImport(FoundationModels)
        return FoundationModelWritingHelpAssistant()
        #else
        return nil
        #endif
    }
}

/// Pure prompt builder — no FM dependency, unit-tested directly regardless of toolchain.
public enum WritingHelpPrompt {
    public static func build(instruction: String, text: String, preamble: String?) -> String {
        let base = """
        \(instruction)

        Text:
        \"\"\"
        \(text)
        \"\"\"

        Reply with only the rewritten text — no preamble, no quotes, no explanation of what changed.
        """
        guard let preamble else { return base }
        return "\(preamble)\n\n\(base)"
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)

/// The production `WritingHelpAssisting`. Goes through `ContentAssistantFactory`/`ContentAssistant`
/// (not a concrete `FoundationModelAssistant` directly) — writing help needs no vision input,
/// so unlike PR 1's alt-text proposer it can and should use the same protocol seam every other
/// one-shot FM feature (`CopyEditAuditor`, `SiteGraphNodeExplainer`) already goes through.
public struct FoundationModelWritingHelpAssistant: WritingHelpAssisting {
    /// Injected so tests can fake the backend without a live model. Production default resolves
    /// through the shared tier seam, matching `CopyEditAuditor`'s own `.privateCloudCompute`
    /// request (today backed on-device; the seam is what changes when real PCC lands).
    private let assistantFactory: @Sendable () -> (any ContentAssistant)?

    public init(assistantFactory: @escaping @Sendable () -> (any ContentAssistant)? = { ContentAssistantFactory.make(tier: .privateCloudCompute) }) {
        self.assistantFactory = assistantFactory
    }

    public func rewrite(
        text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL
    ) async -> WritingHelpOutcome {
        guard let assistant = assistantFactory() else {
            return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
        }
        do {
            let generated = try await assistant.generateStructured(
                prompt: WritingHelpPrompt.build(instruction: instruction, text: text, preamble: preamble),
                context: AssistantContext(siteID: siteID, siteDirectory: siteDirectory),
                resultType: GeneratedRewrite.self
            )
            return .rewritten(generated.rewrittenText)
        } catch {
            return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
        }
    }
}
#endif
```

Note: confirm `ContentHelpDialogs.assistantUnavailable(feature:)`'s exact return string during
implementation (`Sources/AnglesiteCore/ContentHelpDialogs.swift`) — the test above only checks it
contains a recognizable substring, not an exact match, so it's tolerant of the precise wording.

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter "WritingHelpPromptTests|FoundationModelWritingHelpAssistantTests"`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WritingHelpAssistant.swift Sources/AnglesiteCore/GenerableTypes.swift Tests/AnglesiteCoreTests/WritingHelpAssistantTests.swift
git commit -m "$(cat <<'EOF'
feat(#1227): add WritingHelpAssisting FM-backed rewrite core

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `WYSIWYGOpsDispatcher` — new writing-help-request message type

**Files:**
- Modify: `Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift`
- Test: `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift` (append)

**Interfaces:**
- Consumes: `WritingHelpOutcome` (Task 1, the enum only — this task deliberately does NOT depend
  on the `WritingHelpAssisting` protocol; see the closure-typed signature below).
- Produces: `WYSIWYGOpsDispatcher.DispatchResult.writingHelpReply(requestId: String, outcome: WritingHelpOutcome)`
  new case; `WYSIWYGOpsDispatcher.dispatch(body:via:writingHelp:)` new defaulted parameter, typed
  as a plain closure — Task 3's `WYSIWYGScriptHandler` is the consumer, and builds that closure
  itself from a real `WritingHelpAssisting` plus site context. Keeping the dependency
  closure-typed (rather than `(any WritingHelpAssisting)?`) means `AnglesiteBridgeCore` — a
  portable, cross-platform-buildable target — never needs a `siteID`/`siteDirectory`/`preamble`
  concept of its own; that site-scoping stays entirely in `AnglesiteApp`, resolved when the
  closure is *built* (Task 4), not when `dispatch` calls it.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift` (inside the existing
`WYSIWYGOpsDispatcherTests` struct, after the existing tests):

```swift
    @Test("dispatch routes writing-help-request to the assistant and returns the reply")
    func routesWritingHelpRequest() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let body: [String: Any] = ["type": "writing-help-request", "requestId": "wh-1", "text": "Original text.", "instruction": "Tighten this."]
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: body, via: transport,
            writingHelp: { text, instruction in
                #expect(text == "Original text.")
                #expect(instruction == "Tighten this.")
                return .rewritten("Shorter version.")
            })
        guard case .writingHelpReply(let requestId, let outcome) = result else {
            Issue.record("expected .writingHelpReply, got \(result)")
            return
        }
        #expect(requestId == "wh-1")
        #expect(outcome == .rewritten("Shorter version."))
    }

    @Test("dispatch replies .unavailable for writing-help-request when no assistant is wired")
    func writingHelpRequestWithoutAssistant() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let body: [String: Any] = ["type": "writing-help-request", "requestId": "wh-2", "text": "x", "instruction": "y"]
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, writingHelp: nil)
        guard case .writingHelpReply(let requestId, let outcome) = result else {
            Issue.record("expected .writingHelpReply, got \(result)")
            return
        }
        #expect(requestId == "wh-2")
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("dispatch rejects a writing-help-request missing required fields")
    func rejectsMalformedWritingHelpRequest() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "writing-help-request"], via: transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGOpsDispatcherTests`
Expected: FAIL — `dispatch` has no `writingHelp:` parameter; `.writingHelpReply` doesn't exist.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift`:

Update the type header comment (line ~19) to say "Five message types" and add the new one's
description, matching the existing style for the other four.

Add a new `DispatchResult` case, right after `case rejected(RejectionReason)`'s sibling cases
(after `focusInspector`, before `rejected`):

```swift
        /// `writing-help-request` carried text + an instruction for the on-device rewrite
        /// assistant (#1227 PR 2) — the adapter should reply with `outcome` keyed by `requestId`,
        /// same reply shape as `opResult` above.
        case writingHelpReply(requestId: String, outcome: WritingHelpOutcome)
```

Change `dispatch(body:via:)`'s signature to add one new, defaulted closure parameter:

```swift
    public static func dispatch(
        body: Any, via transport: any WYSIWYGHostTransport,
        writingHelp: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)? = nil
    ) async -> DispatchResult {
```

Add a new case to the `switch typeStr` block, after the existing `"focus-inspector"` case and
before `default`:

```swift
        case "writing-help-request":
            guard let requestId = dict["requestId"] as? String,
                  let text = dict["text"] as? String,
                  let instruction = dict["instruction"] as? String
            else {
                return .rejected(.envelopeDecode("could not decode writing-help-request fields"))
            }
            let outcome = await writingHelp?(text, instruction)
                ?? .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
            return .writingHelpReply(requestId: requestId, outcome: outcome)
```

`import AnglesiteCore` is already present (line 2) — `WritingHelpOutcome`/`ContentHelpDialogs` are
`AnglesiteCore` types, already reachable.

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGOpsDispatcherTests`
Expected: PASS (existing tests + 3 new = however many the suite now has, all green). Also run the
full `AnglesiteBridgeCoreTests` filter to catch any other `dispatch(body:via:)` call site broken
by the signature change (there should be none — the new parameters are all defaulted).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(#1227): add writing-help-request to WYSIWYGOpsDispatcher

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Native bridge round-trip — `NativeHostTransport` (JS) + `WYSIWYGScriptHandler` (Swift)

**Files:**
- Modify: `JS/wysiwyg-engine/src/host/native-host-transport.ts`
- Modify: `JS/wysiwyg-engine/src/types.ts` (or a small new file — see Step 3 note)
- Test: `JS/wysiwyg-engine/test/host/native-host-transport.test.ts` (append)
- Modify: `Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift` (exact path: find via
  `find . -iname "WYSIWYGScriptHandler.swift"` — it is NOT in `Sources/AnglesiteApp`; the earlier
  read of its full contents in this plan's research came from that file)

**Interfaces:**
- Consumes: `WYSIWYGOpsDispatcher.DispatchResult.writingHelpReply` (Task 2),
  `WYSIWYGOpsDispatcher.dispatch(body:via:writingHelp:siteID:siteDirectory:preamble:)` (Task 2).
- Produces: JS `NativeHostTransport.requestWritingHelp(text: string, instruction: string): Promise<WritingHelpReply>`
  (new public method) and its `WritingHelpReply` type (`{status: "rewritten", text: string} | {status: "unavailable", message: string}`);
  Swift `WYSIWYGScriptHandler.init(...)` gains `onWritingHelpRequested: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)? = nil` —
  Task 4's only consumption point.

- [ ] **Step 1: Write the failing JS test**

Append to `JS/wysiwyg-engine/test/host/native-host-transport.test.ts`, inside the existing
`describe("NativeHostTransport", ...)` block, after the existing three `it(...)` blocks:

```ts
  it("posts a writing-help-request message and resolves when the native side replies", async () => {
    const transport = new NativeHostTransport();
    const pending = transport.requestWritingHelp("Original text.", "Tighten this.");
    expect(postedMessages).toHaveLength(1);
    const posted = postedMessages[0] as { type: string; requestId: string; text: string; instruction: string };
    expect(posted.type).toBe("writing-help-request");
    expect(posted.text).toBe("Original text.");
    expect(posted.instruction).toBe("Tighten this.");
    expect(typeof posted.requestId).toBe("string");
    (window as any).__anglesiteWysiwygHost._handleWritingHelpResult(posted.requestId, { status: "rewritten", text: "Shorter." });
    await expect(pending).resolves.toEqual({ status: "rewritten", text: "Shorter." });
  });

  it("resolves with an unavailable reply when the native side reports one", async () => {
    const transport = new NativeHostTransport();
    const pending = transport.requestWritingHelp("x", "y");
    const posted = postedMessages[0] as { requestId: string };
    (window as any).__anglesiteWysiwygHost._handleWritingHelpResult(posted.requestId, { status: "unavailable", message: "not available" });
    await expect(pending).resolves.toEqual({ status: "unavailable", message: "not available" });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `JS/wysiwyg-engine/`): `npm test -- native-host-transport.test.ts`
Expected: FAIL — `transport.requestWritingHelp` is not a function.

- [ ] **Step 3: Add the `WritingHelpReply` type and bridge hook**

In `JS/wysiwyg-engine/src/types.ts`, add near the other bridge-adjacent types (after
`RichTextRun`, before `BlockKind`, matches the file's existing top-to-bottom grouping):

```ts
/** Reply to a writing-help request (#1227 PR 2) — mirrors Swift's `WritingHelpOutcome`. */
export type WritingHelpReply =
  | { status: "rewritten"; text: string }
  | { status: "unavailable"; message: string };
```

In `JS/wysiwyg-engine/src/host/native-host-transport.ts`:

Add to the `declare global` block's `__anglesiteWysiwygHost` interface (after `_handleQualityFindings`):

```ts
      _handleWritingHelpResult?: (requestId: string, reply: WritingHelpReply) => void;
```

Update the top import to add `WritingHelpReply`:

```ts
import type { HostTransport, OpEnvelope, OpResult, BlockModel, WritingHelpReply } from "../types.js";
```

Add a new private field alongside `#pending` (same `Map<string, resolver>` shape, separate
namespace so a writing-help `requestId` never collides with an op `requestId`):

```ts
  #pendingWritingHelp = new Map<string, (reply: WritingHelpReply) => void>();
```

In the constructor's `window.__anglesiteWysiwygHost = { ... }` object literal, add a sibling
handler to `_handleOpResult`:

```ts
      _handleWritingHelpResult: (requestId, reply) => {
        const resolve = this.#pendingWritingHelp.get(requestId);
        if (!resolve) return;
        this.#pendingWritingHelp.delete(requestId);
        resolve(reply);
      },
```

Add a new public method, after `sendOp`:

```ts
  requestWritingHelp(text: string, instruction: string): Promise<WritingHelpReply> {
    const requestId = crypto.randomUUID();
    return new Promise((resolve) => {
      this.#pendingWritingHelp.set(requestId, resolve);
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "writing-help-request", requestId, text, instruction });
    });
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `JS/wysiwyg-engine/`): `npm test -- native-host-transport.test.ts`
Expected: PASS (existing 3 + 2 new = 5 tests).

- [ ] **Step 5: Wire the Swift-side reply — `WYSIWYGScriptHandler`**

Locate the file: `find /Users/dwk/Developer/github.com/Anglesite/Anglesite/.claude/worktrees/issue-1227-pr2 -iname "WYSIWYGScriptHandler.swift"`.
It currently declares (per this plan's own research pass — re-read the live file to confirm
before editing, since line numbers may have drifted):

```swift
public final class WYSIWYGScriptHandler: NSObject, WKScriptMessageHandler {
    private let transport: any WYSIWYGHostTransport
    private let logCenter: LogCenter
    private let onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)?
    private let onSelectionChanged: (@Sendable (BlockId?) -> Void)?
    private let onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)?

    public init(
        transport: any WYSIWYGHostTransport, logCenter: LogCenter = .shared,
        onContextMenu: (@Sendable (BlockId, CGPoint) -> Void)? = nil,
        onSelectionChanged: (@Sendable (BlockId?) -> Void)? = nil,
        onFocusInspectorRequested: (@Sendable (WYSIWYGOpsDispatcher.FocusDirection, BlockId) -> Void)? = nil
    ) {
```

Add a new stored property + init parameter, matching the existing closure-injection convention
exactly (this is the seam Task 4 plugs a real `WritingHelpAssisting` into):

```swift
    private let onWritingHelpRequested: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)?
```

Add `onWritingHelpRequested: (@Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome)? = nil`
as the last `init` parameter, and `self.onWritingHelpRequested = onWritingHelpRequested` in the
body.

In `userContentController(_:didReceive:)`, capture the new closure alongside the others
(`let onWritingHelpRequested = self.onWritingHelpRequested`) and pass it straight through as
Task 2's `dispatch(body:via:writingHelp:)` closure parameter — no signature changes needed on the
`AnglesiteBridgeCore` side; `onWritingHelpRequested` already has exactly the shape `dispatch`
expects, since Task 2 was deliberately typed as a closure for this reason.

In the `Task { switch await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, writingHelp: onWritingHelpRequested) { ... }` call, add a new case alongside `.opResult`:

```swift
            case .writingHelpReply(let requestId, let outcome):
                guard let webView else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "webView deallocated before writing-help reply for id=\(requestId)")
                    return
                }
                let replyPayload: [String: Any]
                switch outcome {
                case .rewritten(let text):
                    replyPayload = ["status": "rewritten", "text": text]
                case .unavailable(let message):
                    replyPayload = ["status": "unavailable", "message": message]
                }
                guard JSONSerialization.isValidJSONObject(replyPayload),
                      let data = try? JSONSerialization.data(withJSONObject: replyPayload),
                      let json = String(data: data, encoding: .utf8),
                      let requestIdData = try? JSONEncoder().encode(requestId),
                      let requestIdJSON = String(data: requestIdData, encoding: .utf8)
                else {
                    await logCenter.append(source: "wysiwyg-bridge", stream: .stderr, text: "failed to encode writing-help reply for id=\(requestId)")
                    return
                }
                let script = "window.__anglesiteWysiwygHost?._handleWritingHelpResult?.(\(requestIdJSON), \(json))"
                await MainActor.run { webView.evaluateJavaScript(script) }
```

- [ ] **Step 6: Build and run the affected Swift test suites**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGOpsDispatcherTests`
Expected: PASS (with the simplified closure-based tests). `WYSIWYGScriptHandler` itself has no
existing dedicated test suite covering its `didReceive` switch to extend — if one turns up during
implementation (`find . -iname "WYSIWYGScriptHandlerTests.swift"`), add an equivalent case there
following its existing pattern; otherwise this file's coverage stays at the `WYSIWYGOpsDispatcher`
level (its own switch is the part with real branching logic) plus the app-target build/manual
smoke test in Task 4, matching how PR 1's `SiteWindow.swift` wiring was verified.

- [ ] **Step 7: Commit**

```bash
git add JS/wysiwyg-engine/src/types.ts JS/wysiwyg-engine/src/host/native-host-transport.ts JS/wysiwyg-engine/test/host/native-host-transport.test.ts Sources/AnglesiteBridgeCore/WYSIWYGOpsDispatcher.swift Tests/AnglesiteBridgeCoreTests/WYSIWYGOpsDispatcherTests.swift Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift
git commit -m "$(cat <<'EOF'
feat(#1227): wire writing-help-request through the native bridge

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire a real `WritingHelpAssisting` into the bridge at the app layer

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewView.swift` (new properties + closure construction)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (thread siteID/siteDirectory/conventions into
  `PreviewView`'s construction — find the exact call site via
  `grep -n "PreviewView(" Sources/AnglesiteApp/SiteWindow.swift`)

**Interfaces:**
- Consumes: `WritingHelpAssistantFactory.makeDefault()` (Task 1), `WYSIWYGScriptHandler.init(...onWritingHelpRequested:)`
  (Task 3), `BrandVoiceGuidance.preamble(conventions:businessType:)` (existing),
  `SiteBusinessType.read(sourceDirectory:)` (existing, used identically by PR 1's alt-text path).
- Produces: nothing new for later tasks — this is a leaf wiring task, same shape as PR 1's Task 3.

- [ ] **Step 1: Read the current call sites**

```bash
grep -n "PreviewView(" Sources/AnglesiteApp/SiteWindow.swift
grep -n "wysiwygController.map\|makeWYSIWYGHandler" Sources/AnglesiteApp/PreviewView.swift
```

Confirm what site-scoped values (`siteID`, `sourceDirectory`, `conventionsEngine`) are already
reachable at `PreviewView`'s construction site in `SiteWindow.swift` — this plan's research
confirmed `SiteWindowModel` already threads `conventionsEngine` (private, but Task 4 of PR 1 added
a `currentProjectConventions()` accessor if PR 1 has merged by the time this task runs; if not yet
merged, add an equivalent accessor here rather than depending on an unmerged PR — check
`grep -n "currentProjectConventions" Sources/AnglesiteApp/SiteWindowModel.swift` first and only
add a duplicate if it's genuinely absent).

- [ ] **Step 2: Thread `siteID`/`siteDirectory`/`conventions` into `PreviewView`**

In `Sources/AnglesiteApp/PreviewView.swift`, add two new stored properties near `wysiwygTransport`:

```swift
    /// The open site's id and source directory — needed to build a `WritingHelpAssisting` call's
    /// `AssistantContext` and brand-voice preamble (#1227 PR 2). `nil` outside edit mode exactly
    /// like `wysiwygTransport`, since writing help is a WYSIWYG-canvas-only feature.
    var writingHelpSiteContext: (siteID: String, siteDirectory: URL, conventions: ProjectConventions?)?
```

In `makeWYSIWYGHandler(for:coordinator:)`, add the new closure to the `WYSIWYGScriptHandler` init
call:

```swift
            onWritingHelpRequested: writingHelpSiteContext.map { context in
                { (text: String, instruction: String) async -> WritingHelpOutcome in
                    guard let assistant = WritingHelpAssistantFactory.makeDefault() else {
                        return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
                    }
                    let businessType = SiteBusinessType.read(sourceDirectory: context.siteDirectory)
                    let preamble = BrandVoiceGuidance.preamble(conventions: context.conventions, businessType: businessType)
                    return await assistant.rewrite(
                        text: text, instruction: instruction, preamble: preamble,
                        siteID: context.siteID, siteDirectory: context.siteDirectory)
                }
            }
```

- [ ] **Step 3: Pass real values from `SiteWindow.swift`**

At `PreviewView(...)`'s construction site in `SiteWindow.swift`, add the new argument:

```swift
writingHelpSiteContext: model.preview.openSiteID.map { siteID in
    (siteID: siteID, sourceDirectory: model.preview.openSiteDirectory ?? URL(fileURLWithPath: "/"),
     conventions: model.currentProjectConventions())
}
```

(Adjust to match whatever the actual call site's existing argument style looks like — trailing
closure vs. explicit dictionary construction — read the surrounding lines first.) If
`model.currentProjectConventions()` doesn't exist yet (PR 1 not merged), add it exactly as PR 1's
plan defined it: a small method on `SiteWindowModel` returning `conventionsEngine.conventions(siteID:)`
for the current `site?.id`, `async` (per PR 1's own final-review-caught correction: `ProjectConventionsEngine`
is an `actor`, so this must be `async` and awaited).

- [ ] **Step 4: Build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual smoke test (documented limitation, same as PR 1)**

This wiring can't be exercised by an automated test (it's a `.onDrop`-adjacent app-layer closure
requiring a live `WKWebView`). If a GUI-automation tool is available in this environment, verify:
open a site, enable Edit Page, select text in a paragraph block, and confirm a request round-trips
(the toolbar itself doesn't exist until Tasks 5-6 — for now, this is verifiable only by a temporary
debug call or deferred to Task 6's own smoke test). If no such tool is available, note this
explicitly in the task report exactly as PR 1's Task 3 did, for human verification before merge.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/PreviewView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(cat <<'EOF'
feat(#1227): wire WritingHelpAssisting into the WYSIWYG bridge handler

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `RichTextEditor` — expose selection context and a DOM-replace-and-commit method

**Files:**
- Modify: `JS/wysiwyg-engine/src/rich-text.ts`
- Test: `JS/wysiwyg-engine/test/rich-text.test.ts` (append; non-Selection-dependent parts only —
  see Global Constraints)

**Interfaces:**
- Consumes: `runsFromElement(el: Element): RichTextRun[]` (existing, `rich-text.ts`), `WysiwygEngine.submit`
  (existing, via `this.#engine.submit`).
- Produces: `RichTextEditor.currentSelectionContext(doc: Document = document): { blockId: BlockId; range: Range; text: string } | null`;
  `RichTextEditor.applyTextReplacement(range: Range, newText: string): void` — Task 6's only
  consumption points on this class.

- [ ] **Step 1: Write the failing tests (non-Selection-dependent behavior only)**

Append to `JS/wysiwyg-engine/test/rich-text.test.ts` (read the file's existing top-of-file imports
and `describe` structure first to match its conventions exactly — it already imports `RichTextEditor`
and constructs a fake/stub engine for `RichTextEditor`'s non-DOM-Selection tests):

```ts
describe("RichTextEditor.currentSelectionContext", () => {
  it("returns null when there is no active block being edited", () => {
    const engine = { modelSync: { getBlock: () => undefined }, submit: async () => {} } as any;
    const editor = new RichTextEditor(engine);
    expect(editor.currentSelectionContext(document)).toBeNull();
  });
});
```

Note: a *positive* case (a real selection returning a non-null context) is a live-`Selection`
behavior — per this package's established split, that belongs in a Playwright e2e golden (added
in Task 6, where the whole toolbar interaction is exercised end-to-end), not here. This task's
jsdom coverage is deliberately limited to the "nothing is being edited" guard clause — the one
branch that doesn't depend on real `Selection` behavior jsdom can't provide.

- [ ] **Step 2: Run test to verify it fails**

Run (from `JS/wysiwyg-engine/`): `npm test -- rich-text.test.ts`
Expected: FAIL — `editor.currentSelectionContext` is not a function.

- [ ] **Step 3: Implement**

In `JS/wysiwyg-engine/src/rich-text.ts`, add two new public methods to the `RichTextEditor` class,
after `get activeElementForTesting()`:

```ts
  /**
   * The current text selection's context, if one exists inside the block currently being edited
   * (#1227 PR 2) — `null` when nothing is active, the selection is collapsed (a caret, not a
   * range), or the selection lies outside the active element. Selection-live-behavior is exactly
   * `toggleInlineFormat`'s own guard shape (this file, above) — same reasoning, same Selection
   * API usage.
   */
  currentSelectionContext(doc: Document = document): { blockId: BlockId; range: Range; text: string } | null {
    if (this.#activeBlockId === null || this.#activeElement === null) return null;
    const selection = doc.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    if (!this.#activeElement.contains(range.commonAncestorContainer)) return null;
    const text = range.toString();
    if (text.length === 0) return null;
    return { blockId: this.#activeBlockId, range, text };
  }

  /**
   * Replaces `range`'s live DOM content with `newText`, then re-serializes and submits an
   * `editText` op through the same commit path typing already uses — no positional run-splicing
   * (see plan Global Constraints): the DOM mutation plus `runsFromElement` re-serialization is
   * the "diff." `previousRuns` is this editor's `enter()`-time baseline, same invariant `#commit()`
   * already preserves — a version-mismatch rejection mid-flow still discards the whole pending
   * edit in one step.
   */
  applyTextReplacement(range: Range, newText: string): void {
    if (this.#activeBlockId === null || this.#activeElement === null) return;
    range.deleteContents();
    range.insertNode(document.createTextNode(newText));
    // Collapse and clear the live selection so a stray leftover Range doesn't confuse the next
    // selectionchange listener (the toolbar's own trigger, added in Task 6) into reopening itself
    // immediately after Accept.
    const selection = document.getSelection();
    selection?.removeAllRanges();
    const runs = runsFromElement(this.#activeElement);
    void this.#engine.submit({
      kind: "editText",
      blockId: this.#activeBlockId,
      runs,
      previousRuns: this.#baselineRuns,
    });
    this.#baselineRuns = runs;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `JS/wysiwyg-engine/`): `npm test -- rich-text.test.ts`
Expected: PASS (existing suite + 1 new test).

- [ ] **Step 5: Commit**

```bash
git add JS/wysiwyg-engine/src/rich-text.ts JS/wysiwyg-engine/test/rich-text.test.ts
git commit -m "$(cat <<'EOF'
feat(#1227): expose selection context + DOM-replace-and-commit on RichTextEditor

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `SelectionToolbar` — the canvas UI, Playwright e2e golden, and `mount.ts` wiring

**Files:**
- Create: `JS/wysiwyg-engine/src/host/selection-toolbar.ts`
- Modify: `JS/wysiwyg-engine/src/host/mount.ts` (wire into `mount()`/`disposeMounted()`)
- Test: `JS/wysiwyg-engine/test/host/selection-toolbar.test.ts` (new — non-Selection-dependent
  parts: instruction-string construction, keyed rendering of the preview state)
- Test: `JS/wysiwyg-engine/e2e/selection-toolbar.spec.ts` (new — live-Selection behavior; read an
  existing spec in `JS/wysiwyg-engine/e2e/` first to match its Playwright conventions exactly
  before writing this one)

**Interfaces:**
- Consumes: `RichTextEditor.currentSelectionContext`/`applyTextReplacement` (Task 5),
  `NativeHostTransport.requestWritingHelp(text:instruction:)` (Task 3), `WritingHelpReply` (Task 3).
- Produces: `SelectionToolbar` class, constructed as `new SelectionToolbar(richTextEditor, transport, document)`
  and disposed via `.dispose()` — `mount.ts`'s only new call sites.

- [ ] **Step 1: Read an existing Playwright spec for conventions**

```bash
ls JS/wysiwyg-engine/e2e/
cat JS/wysiwyg-engine/playwright.config.ts
```

Read one existing `.spec.ts` file in full (whichever covers `toggleInlineFormat`/rich-text
selection behavior, if one exists, else any block-selection spec) to match its page-object /
fixture / assertion conventions before writing the new one in Step 6.

- [ ] **Step 2: Write the failing non-Selection unit test**

```ts
// JS/wysiwyg-engine/test/host/selection-toolbar.test.ts
// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { instructionForAction } from "../../src/host/selection-toolbar.js";

describe("instructionForAction", () => {
  it("builds a canned instruction for rewrite", () => {
    expect(instructionForAction("rewrite")).toContain("clearer");
  });

  it("builds a canned instruction for tighten", () => {
    expect(instructionForAction("tighten")).toMatch(/shorter/i);
  });

  it("builds a canned instruction for a tone preset", () => {
    const friendlier = instructionForAction("tone", "friendlier");
    const formal = instructionForAction("tone", "more formal");
    expect(friendlier).toContain("friendlier");
    expect(formal).toContain("more formal");
    expect(friendlier).not.toBe(formal);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run (from `JS/wysiwyg-engine/`): `npm test -- selection-toolbar.test.ts`
Expected: FAIL — module `../../src/host/selection-toolbar.js` doesn't exist.

- [ ] **Step 4: Implement `instructionForAction` and the `SelectionToolbar` class**

```ts
// JS/wysiwyg-engine/src/host/selection-toolbar.ts
import type { RichTextEditor } from "../rich-text.js";
import type { HostTransport } from "../types.js";

/** Extends `HostTransport` with the writing-help round trip (#1227 PR 2, Task 3). */
export interface WritingHelpTransport extends HostTransport {
  requestWritingHelp(text: string, instruction: string): Promise<{ status: "rewritten"; text: string } | { status: "unavailable"; message: string }>;
}

export type ToolbarAction = "rewrite" | "tighten" | "tone";
export type TonePreset = "friendlier" | "more formal" | "more confident";

/** Canned instruction text per toolbar action (plan Global Constraints: one instruction-taking
 *  API, no action enum on the host side — the action→instruction mapping lives entirely here). */
export function instructionForAction(action: ToolbarAction, tone?: TonePreset): string {
  switch (action) {
    case "rewrite":
      return "Rewrite this to be clearer and more engaging, keeping roughly the same length and meaning.";
    case "tighten":
      return "Make this noticeably shorter while keeping the essential meaning.";
    case "tone":
      return `Rewrite this in a ${tone ?? "friendlier"} tone, keeping the same meaning and roughly the same length.`;
  }
}

const TOOLBAR_Z_INDEX = "2147483000";

/**
 * Floating selection toolbar (#1227 PR 2, design doc §4): appears on a non-collapsed text
 * selection inside the block currently being edited, offers Rewrite/Tighten/Tone(preset) buttons,
 * and shows a before/after preview with Accept/Discard after a request round-trips. Positioning
 * and inline-style conventions follow `QualityGateChips` (this package's existing chip precedent)
 * even though the trigger direction is the opposite: this is JS-locally `selectionchange`-driven,
 * not a host push.
 */
export class SelectionToolbar {
  #richTextEditor: RichTextEditor;
  #transport: WritingHelpTransport;
  #doc: Document;
  #el: HTMLElement | null = null;
  #pendingRange: Range | null = null;
  #onSelectionChange = () => this.#handleSelectionChange();

  constructor(richTextEditor: RichTextEditor, transport: WritingHelpTransport, doc: Document = document) {
    this.#richTextEditor = richTextEditor;
    this.#transport = transport;
    this.#doc = doc;
    doc.addEventListener("selectionchange", this.#onSelectionChange);
  }

  dispose(): void {
    this.#doc.removeEventListener("selectionchange", this.#onSelectionChange);
    this.#el?.remove();
    this.#el = null;
  }

  #handleSelectionChange(): void {
    const context = this.#richTextEditor.currentSelectionContext(this.#doc);
    if (!context) {
      this.#hide();
      return;
    }
    this.#showButtons(context.range);
  }

  #hide(): void {
    this.#el?.remove();
    this.#el = null;
    this.#pendingRange = null;
  }

  #showButtons(range: Range): void {
    this.#el?.remove();
    const el = this.#doc.createElement("div");
    el.style.cssText = `position:fixed;z-index:${TOOLBAR_Z_INDEX};display:flex;gap:4px;padding:4px;background:#1f2937;border-radius:6px;box-shadow:0 2px 8px rgba(0,0,0,0.3);`;
    const rect = range.getBoundingClientRect();
    el.style.left = `${Math.max(0, rect.left)}px`;
    el.style.top = `${Math.max(0, rect.top - 40)}px`;

    const addButton = (label: string, action: ToolbarAction, tone?: TonePreset) => {
      const button = this.#doc.createElement("button");
      button.textContent = label;
      button.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;";
      button.addEventListener("click", () => this.#request(range, action, tone));
      el.appendChild(button);
    };
    addButton("Rewrite", "rewrite");
    addButton("Tighten", "tighten");
    addButton("Friendlier", "tone", "friendlier");
    addButton("More Formal", "tone", "more formal");
    addButton("More Confident", "tone", "more confident");

    this.#doc.body.appendChild(el);
    this.#el = el;
  }

  async #request(range: Range, action: ToolbarAction, tone?: TonePreset): Promise<void> {
    this.#pendingRange = range;
    const text = range.toString();
    this.#renderLoading();
    const reply = await this.#transport.requestWritingHelp(text, instructionForAction(action, tone));
    // The selection (and thus the active edit) may have moved on during the round trip — discard
    // a stale reply rather than force-applying it to whatever is selected now.
    if (this.#pendingRange !== range) return;
    if (reply.status === "unavailable") {
      this.#renderError(reply.message);
      return;
    }
    this.#renderPreview(text, reply.text, range);
  }

  #renderLoading(): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const label = this.#doc.createElement("span");
    label.textContent = "Rewriting…";
    label.style.cssText = "font-size:12px;color:#e5e7eb;padding:2px 4px;";
    this.#el.appendChild(label);
  }

  #renderError(message: string): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const label = this.#doc.createElement("span");
    label.textContent = message;
    label.style.cssText = "font-size:12px;color:#fca5a5;padding:2px 4px;max-width:240px;";
    this.#el.appendChild(label);
  }

  #renderPreview(original: string, rewritten: string, range: Range): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const preview = this.#doc.createElement("div");
    preview.style.cssText = "font-size:12px;color:#e5e7eb;max-width:280px;";
    preview.textContent = rewritten;
    this.#el.appendChild(preview);

    const accept = this.#doc.createElement("button");
    accept.textContent = "Accept";
    accept.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;background:#16a34a;color:white;";
    accept.addEventListener("click", () => {
      this.#richTextEditor.applyTextReplacement(range, rewritten);
      this.#hide();
    });

    const discard = this.#doc.createElement("button");
    discard.textContent = "Discard";
    discard.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;";
    discard.addEventListener("click", () => this.#hide());

    this.#el.appendChild(accept);
    this.#el.appendChild(discard);
  }
}
```

- [ ] **Step 5: Run the unit test to verify it passes**

Run (from `JS/wysiwyg-engine/`): `npm test -- selection-toolbar.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 6: Write the Playwright e2e golden for the live-Selection path**

Following the conventions read in Step 1, write
`JS/wysiwyg-engine/e2e/selection-toolbar.spec.ts` covering: selecting text inside an editable
block shows the toolbar with Rewrite/Tighten/tone buttons; clicking a button shows a loading
state then a preview with Accept/Discard (stub `requestWritingHelp` at the page level, matching
however existing specs stub the transport — check for a `page.evaluate` / `page.exposeFunction`
convention already in use); clicking Accept replaces the selected text in the DOM and the toolbar
hides; clicking Discard leaves the original text untouched and the toolbar hides. Do not
hand-write the exact Playwright API calls without first reading a real existing spec in this
directory — mirror its fixture setup exactly rather than inventing a new one.

Run (from `JS/wysiwyg-engine/`): `npx playwright test selection-toolbar.spec.ts`
Expected: PASS. If Playwright's browsers aren't installed in this environment, run
`npx playwright install` first (matching whatever this repo's other e2e specs document as their
setup step — check `JS/wysiwyg-engine/README.md` or `package.json` scripts for an existing
`pretest`/`playwright:install` convention before assuming this step).

- [ ] **Step 7: Wire into `mount.ts`**

In `JS/wysiwyg-engine/src/host/mount.ts`, add a new global slot alongside the existing ones
(`window.__anglesiteWysiwygSelectionToolbar?: SelectionToolbar`), disposed in `disposeMounted()`
right after `window.__anglesiteWysiwygQualityGates?.dispose()` (same ordering position — after
the gates, before keyboard nav, matching the existing dispose-in-reverse-of-construction-adjacency
pattern already visible in that function), and constructed in `mount()` right after
`window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport)`:

```ts
    window.__anglesiteWysiwygSelectionToolbar = new SelectionToolbar(
      window.__anglesiteWysiwygRichTextEditor, transport, document);
```

Add the import at the top of `mount.ts`: `import { SelectionToolbar } from "./selection-toolbar.js";`.
Add the type declaration to whatever `declare global { interface Window { ... } }` block already
declares the sibling `window.__anglesiteWysiwygQualityGates` slot.

- [ ] **Step 8: Run the full JS suite**

Run (from `JS/wysiwyg-engine/`): `npm run lint && npm run typecheck && npm test`
Expected: all green, no new lint/type errors.

- [ ] **Step 9: Commit**

```bash
git add JS/wysiwyg-engine/src/host/selection-toolbar.ts JS/wysiwyg-engine/src/host/mount.ts JS/wysiwyg-engine/test/host/selection-toolbar.test.ts JS/wysiwyg-engine/e2e/selection-toolbar.spec.ts
git commit -m "$(cat <<'EOF'
feat(#1227): add the WYSIWYG selection toolbar for writing help

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `WYSIWYGBlockTextAccess` + `RewriteBlockTool` — the chat front door

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockTextAccess.swift`
- Create: `Sources/AnglesiteCore/RewriteBlockTool.swift`
- Test: `Tests/AnglesiteCoreTests/RewriteBlockToolTests.swift`

**Interfaces:**
- Consumes: `WritingHelpAssisting.rewrite(text:instruction:preamble:siteID:siteDirectory:)`
  (Task 1), `WritingHelpOutcome` (Task 1).
- Produces: `WYSIWYGBlockTextAccess: Sendable` protocol with
  `func blockText(_ id: String) async -> String?` and
  `func submitRewrite(blockId: String, newText: String) async -> Bool`; `RewriteBlockReply`
  (pure reply-string builder, non-gated); `RewriteBlockTool` (FM `Tool`, gated) — Task 8's only
  consumption points.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/RewriteBlockToolTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("RewriteBlockReply")
struct RewriteBlockReplyTests {
    @Test("confirmation names the block was rewritten")
    func confirmationNamesSuccess() {
        #expect(RewriteBlockReply.confirmation(for: .success).contains("rewrote"))
    }

    @Test("blockNotFound explains the block couldn't be located")
    func blockNotFoundExplains() {
        #expect(RewriteBlockReply.confirmation(for: .blockNotFound).lowercased().contains("couldn't find"))
    }

    @Test("unavailable passes through the assistant's own message")
    func unavailablePassesThroughMessage() {
        #expect(RewriteBlockReply.confirmation(for: .unavailable("Apple Intelligence isn't available.")).contains("Apple Intelligence isn't available."))
    }

    @Test("submitFailed explains the rewrite generated but couldn't be applied")
    func submitFailedExplains() {
        #expect(RewriteBlockReply.confirmation(for: .submitFailed).lowercased().contains("couldn't apply"))
    }
}

// Gated like the type under test — `RewriteBlockTool` is a FoundationModels `Tool`. The reply
// logic above is model-free and always tested; the tool itself is exercised through a fake
// `WYSIWYGBlockTextAccess` + `WritingHelpAssisting`.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("RewriteBlockTool")
struct RewriteBlockToolTests {
    private struct FakeAccess: WYSIWYGBlockTextAccess {
        var text: String?
        var submitResult = true
        func blockText(_ id: String) async -> String? { text }
        func submitRewrite(blockId: String, newText: String) async -> Bool { submitResult }
    }

    private struct FakeWritingHelp: WritingHelpAssisting {
        let outcome: WritingHelpOutcome
        func rewrite(text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL) async -> WritingHelpOutcome { outcome }
    }

    @Test("rewrites and submits when the block exists and generation succeeds")
    func rewritesAndSubmits() async throws {
        let tool = RewriteBlockTool(
            access: FakeAccess(text: "Original paragraph."),
            writingHelp: FakeWritingHelp(outcome: .rewritten("Punchier paragraph.")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "make this punchier"))
        #expect(reply.contains("rewrote"))
    }

    @Test("replies blockNotFound when the block id doesn't resolve")
    func repliesBlockNotFound() async throws {
        let tool = RewriteBlockTool(
            access: FakeAccess(text: nil),
            writingHelp: FakeWritingHelp(outcome: .rewritten("x")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "missing", instruction: "y"))
        #expect(reply.lowercased().contains("couldn't find"))
    }

    @Test("passes through the assistant's unavailable message without submitting")
    func repliesUnavailable() async throws {
        let access = FakeAccess(text: "Original.")
        let tool = RewriteBlockTool(
            access: access,
            writingHelp: FakeWritingHelp(outcome: .unavailable("Apple Intelligence isn't available.")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "y"))
        #expect(reply.contains("Apple Intelligence isn't available."))
    }

    @Test("replies unavailable immediately, without reading the block, when no assistant is wired")
    func repliesUnavailableWithNilAssistant() async throws {
        let tool = RewriteBlockTool(
            access: FakeAccess(text: "Original."), writingHelp: nil,
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "y"))
        #expect(reply.contains("Apple Intelligence") || reply.contains("available"))
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter "RewriteBlockReplyTests|RewriteBlockToolTests"`
Expected: FAIL — cannot find `WYSIWYGBlockTextAccess`/`RewriteBlockTool`/`RewriteBlockReply`.

- [ ] **Step 3: Implement `WYSIWYGBlockTextAccess`**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockTextAccess.swift
import Foundation

/// Read/write seam from a chat `Tool` (which lives in `AnglesiteCore`) into the live WYSIWYG
/// canvas (which lives in `AnglesiteApp` — the wrong dependency direction for a direct reference,
/// confirmed by inspection: `AnglesiteCore` cannot import `AnglesiteApp`). `WYSIWYGCanvasController`
/// conforms to this in `AnglesiteApp` (Task 8); `AnglesiteCore` only ever sees it as `any
/// WYSIWYGBlockTextAccess`, exactly the pattern `IntentEditBridge` already uses for the legacy
/// overlay editor's own cross-module seam.
public protocol WYSIWYGBlockTextAccess: Sendable {
    /// The block's current plain text, or `nil` when no block with this id exists (e.g. it was
    /// deleted, or the canvas isn't mounted at all).
    func blockText(_ id: String) async -> String?
    /// Submits `newText` as a full plain-text replacement for the block's rich text (an `editText`
    /// op — see plan Global Constraints on formatting loss). Returns whether the op applied.
    func submitRewrite(blockId: String, newText: String) async -> Bool
}
```

- [ ] **Step 4: Implement `RewriteBlockTool`**

```swift
// Sources/AnglesiteCore/RewriteBlockTool.swift
import Foundation

/// Pure reply strings for `RewriteBlockTool`, non-gated for CI tests.
public enum RewriteBlockReply {
    public enum Outcome: Equatable {
        case success
        case blockNotFound
        case unavailable(String)
        case submitFailed
    }

    public static func confirmation(for outcome: Outcome) -> String {
        switch outcome {
        case .success:
            return "I rewrote that block. Undo (⌘Z) if you don't like it."
        case .blockNotFound:
            return "I couldn't find that block on the page — it may have been deleted or the page may have changed since you last saw it."
        case .unavailable(let message):
            return message
        case .submitFailed:
            return "I generated a rewrite, but couldn't apply it to the page — the document may have changed underneath it. Try again."
        }
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

/// Chat front door for writing help on a whole block (#1227 PR 2, design doc §4) — the
/// `rewriteBlock` counterpart to the canvas selection toolbar (Task 6), operating on a block's
/// full current text rather than a live selection. Applies immediately (with Undo as the safety
/// net) rather than requiring a separate in-chat accept step — chat has no existing
/// "inline-action-in-transcript" affordance to build a preview-then-apply UI on top of (confirmed
/// by inspection of the existing `Tool` call sites), and immediate-apply-with-Undo is the same
/// resolution PR 1's alt-text proposal already uses for a comparable "reviewable, not gated on an
/// extra click" tradeoff.
public struct RewriteBlockTool: Tool, Sendable {
    public static let toolName = "rewriteBlock"
    public let name = RewriteBlockTool.toolName
    public let description = "Rewrite an existing block's text per the owner's instruction (e.g. 'make the hero heading punchier'). Needs the block's id — ask the owner to select it first if you don't already know which block they mean, or use context from earlier in the conversation."

    @Generable
    public struct Arguments {
        @Guide(description: "The id of the block to rewrite.")
        public var blockId: String
        @Guide(description: "The owner's rewrite instruction, in their own words.")
        public var instruction: String

        public init(blockId: String, instruction: String) {
            self.blockId = blockId
            self.instruction = instruction
        }
    }

    private let access: any WYSIWYGBlockTextAccess
    /// Optional so a caller can attach this tool even when `WritingHelpAssistantFactory.makeDefault()`
    /// returned `nil` — `call` degrades to `.unavailable` immediately rather than needing a
    /// non-functional fallback conformer (there is no meaningful non-optional default: any stand-in
    /// would just re-implement the same "always unavailable" behavior `nil` already expresses).
    private let writingHelp: (any WritingHelpAssisting)?
    private let siteID: String
    private let siteDirectory: URL

    public init(access: any WYSIWYGBlockTextAccess, writingHelp: (any WritingHelpAssisting)?, siteID: String, siteDirectory: URL) {
        self.access = access
        self.writingHelp = writingHelp
        self.siteID = siteID
        self.siteDirectory = siteDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let writingHelp else {
            return RewriteBlockReply.confirmation(for: .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help")))
        }
        guard let text = await access.blockText(arguments.blockId) else {
            return RewriteBlockReply.confirmation(for: .blockNotFound)
        }
        let outcome = await writingHelp.rewrite(
            text: text, instruction: arguments.instruction, preamble: nil,
            siteID: siteID, siteDirectory: siteDirectory)
        switch outcome {
        case .unavailable(let message):
            return RewriteBlockReply.confirmation(for: .unavailable(message))
        case .rewritten(let newText):
            let applied = await access.submitRewrite(blockId: arguments.blockId, newText: newText)
            return RewriteBlockReply.confirmation(for: applied ? .success : .submitFailed)
        }
    }
}
#endif
```

Note: `preamble: nil` here is a deliberate v1 gap, not an oversight — threading
`BrandVoiceGuidance` into the chat-tool path needs a `ProjectConventions?` value, which isn't
available at this tool's construction site without extending `SiteAssistantSessionFactory`'s
already-large parameter list further. Task 8 wires the tool itself; folding brand-voice guidance
into it is a reasonable fast-follow once Task 8's threading is in place, not blocking for this PR.

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter "RewriteBlockReplyTests|RewriteBlockToolTests"`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGBlockTextAccess.swift Sources/AnglesiteCore/RewriteBlockTool.swift Tests/AnglesiteCoreTests/RewriteBlockToolTests.swift
git commit -m "$(cat <<'EOF'
feat(#1227): add rewriteBlock chat tool + WYSIWYGBlockTextAccess seam

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Thread the seam through — `WYSIWYGCanvasController` conformance + assistant wiring

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift` (add `WYSIWYGBlockTextAccess`
  conformance)
- Modify: `Sources/AnglesiteApp/AssistantSessionAssembler.swift` (thread a lazy provider, same
  shape as `mcpClient`/`containerControlProvider`)
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift` (`AssistantBuilder` typealias +
  `Dependencies.live` construction + `makeSession` signature)
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (new stored property, init
  parameter, `conversationTools`/`attachedToolNames` entries)

**Interfaces:**
- Consumes: `WYSIWYGBlockTextAccess` (Task 7), `RewriteBlockTool` (Task 7),
  `WritingHelpAssistantFactory.makeDefault()` (Task 1), `WYSIWYGCanvasController.model.blocks[id]`
  / `WYSIWYGBlockClipboardWriter.render(_:).plainText` (existing), `WYSIWYGCanvasController.submit(_:)`
  (existing).
- Produces: nothing later tasks depend on — this is the plan's final leaf-wiring task.

- [ ] **Step 1: `WYSIWYGCanvasController` conforms to `WYSIWYGBlockTextAccess`**

In `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`, add a new extension (this file already
imports `AnglesiteCore`, where the protocol lives):

```swift
extension WYSIWYGCanvasController: WYSIWYGBlockTextAccess {
    func blockText(_ id: String) async -> String? {
        guard let node = model.blocks[id] else { return nil }
        return WYSIWYGBlockClipboardWriter.render(node).plainText
    }

    /// Replaces the block's rich text with a single plain-text run (see plan Global Constraints
    /// on formatting loss — a chat-driven whole-block rewrite has no selection-scoped DOM to
    /// mutate the way the canvas toolbar's `applyTextReplacement` does, so this always replaces
    /// the block's entire content).
    func submitRewrite(blockId: String, newText: String) async -> Bool {
        guard let node = model.blocks[blockId] else { return false }
        let runs = [RichTextRun(kind: .text, text: newText, href: nil, children: nil)]
        let result = await submit(.editText(blockId: blockId, runs: runs, previousRuns: node.richText ?? []))
        if case .applied = result { return true }
        return false
    }
}
```

Confirm `RichTextRun`'s exact Swift initializer signature before writing this (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`,
around line 42-57) — adjust field order/names if they've drifted from `kind:text:href:children:`.

- [ ] **Step 2: Thread a lazy provider through `AssistantSessionAssembler`**

In `Sources/AnglesiteApp/AssistantSessionAssembler.swift`, add a new parameter to `makeSession`:

```swift
    static func makeSession(
        for site: CurrentSite,
        preview: PreviewModel,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine,
        integrationService: any IntegrationOperationsService,
        graphSnapshotProvider: @escaping SiteAssistantSessionFactory.GraphSnapshotProvider
    ) -> SiteAssistantSession {
        let mcpClient: @Sendable () async -> MCPClient? = { [preview] in
            await preview.mcpClient()
        }
```

Add, right after the existing `mcpClient`/`containerControlProvider` closures:

```swift
        // Resolved lazily, same reasoning as `mcpClient`/`containerControlProvider` above: the
        // canvas mounts/unmounts as the owner toggles Site ▸ Edit Page, so this must re-check
        // `preview.wysiwygCanvas` at call time, not capture a possibly-nil snapshot now (#1227 PR 2).
        let wysiwygBlockAccess: @Sendable () async -> (any WYSIWYGBlockTextAccess)? = { [preview] in
            await preview.wysiwygCanvas
        }
```

Pass it through to `SiteAssistantSessionFactory.makeSession(...)`'s call at the bottom of this
function, as a new `wysiwygBlockAccess: wysiwygBlockAccess` argument.

- [ ] **Step 3: Extend `SiteAssistantSessionFactory`**

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`:

Add a new typealias near `AssistantBuilder`:

```swift
    typealias WYSIWYGBlockAccessProvider = @Sendable () async -> (any WYSIWYGBlockTextAccess)?
```

Add a new parameter to the `AssistantBuilder` typealias (after `designInterviewFactory`, before
`graphSnapshotProvider`):

```swift
        _ wysiwygBlockAccess: (any WYSIWYGBlockTextAccess)?,
```

Add a new parameter to `makeSession(...)`:

```swift
        wysiwygBlockAccess: @escaping WYSIWYGBlockAccessProvider,
```

Inside `makeSession`, resolve it once (it's a provider, not the value itself, matching
`containerControlProvider`'s own call-time-resolution shape) and pass the resolved value into the
`assistant` builder call:

```swift
        let resolvedWysiwygAccess = await wysiwygBlockAccess()
```

Add `resolvedWysiwygAccess` to the `dependencies.assistant(...)` call's argument list, in the
matching position.

In `Dependencies.live`'s `assistant: AssistantBuilder = { editBridge, contentGraph, ..., designInterviewFactory, wysiwygBlockAccess, graphSnapshotProvider in ... }` closure (add the new
parameter name to the closure's parameter list in the matching position), pass
`wysiwygBlockAccess` through to `FoundationModelAssistant(...)`'s init call as a new
`wysiwygBlockAccess: wysiwygBlockAccess` argument.

- [ ] **Step 4: Extend `FoundationModelAssistant`**

In `Sources/AnglesiteCore/FoundationModelAssistant.swift`:

Add a stored property near `postRepurposer`:

```swift
    private let wysiwygBlockAccess: (any WYSIWYGBlockTextAccess)?
```

Add an init parameter (after `postRepurposer`, before `themeCatalog`) and assign it in the body:
`wysiwygBlockAccess: (any WYSIWYGBlockTextAccess)? = nil`.

In `conversationTools(for:includeSpotlight:)`, add, after the `postRepurposer` block:

```swift
        if let wysiwygBlockAccess {
            tools.append(RewriteBlockTool(
                access: wysiwygBlockAccess, writingHelp: WritingHelpAssistantFactory.makeDefault(),
                siteID: context.siteID, siteDirectory: context.siteDirectory))
        }
```

`RewriteBlockTool`'s `writingHelp` parameter is `(any WritingHelpAssisting)?` (Task 7) precisely
so this call site can pass `WritingHelpAssistantFactory.makeDefault()`'s result straight through —
`nil` there just means the tool is still attached (it needs `wysiwygBlockAccess` to attach at
all) but every call replies `.unavailable` immediately, per Task 7's `call` implementation. No
fallback conformer needed.

In `attachedToolNames`, add, after the `postRepurposer` block:

```swift
        if wysiwygBlockAccess != nil {
            names.append(RewriteBlockTool.toolName)
        }
```

- [ ] **Step 5: Check for other `FoundationModelAssistant(` call sites broken by the new parameter**

```bash
grep -rn "FoundationModelAssistant(" Sources/ Tests/ | grep -v "^Sources/AnglesiteCore/FoundationModelAssistant.swift"
```

The new parameter is defaulted (`= nil`), so this should be source-compatible everywhere — confirm
by inspection rather than assuming.

- [ ] **Step 6: Build and run the full Core test suite**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh`
Expected: PASS (all suites — this task changes a widely-depended-on init signature, so a full run,
not just a filtered one, is the right check here).

- [ ] **Step 7: Manual smoke test (documented limitation, same as PR 1 and Task 4)**

If a GUI-automation tool is available: open a site, enable Edit Page, open chat, ask "rewrite the
hero heading to be punchier" (or similar), and confirm the block's text changes and Undo reverts
it. If not available in this environment, note this explicitly in the task report for human
verification before merge, exactly as PR 1's Task 3 and this plan's Task 4 already do.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/AssistantSessionAssembler.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Sources/AnglesiteCore/FoundationModelAssistant.swift
git commit -m "$(cat <<'EOF'
feat(#1227): thread rewriteBlock tool into the chat assistant

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-plan

- Open the PR referencing #1227 without a closing keyword (per Global Constraints), using
  `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings per `CONTRIBUTING.md`. Base it against
  `main`, not PR 1's branch (this worktree already forked from `origin/main` directly).
- Two documented v1 gaps worth naming in the PR body: (1) the `rewriteBlock` chat tool has no
  brand-voice preamble yet (Task 7's note); (2) neither front-door has been exercised live in the
  running app in this environment (Tasks 4/8's manual-smoke-test notes) — needs human
  verification before/soon after merge, same as PR 1.
- PR 3 (block-type suggestions, closes #1227) is a separate plan, written after this one lands.
