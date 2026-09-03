import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnglesiteCore
import AnglesiteSiteModel

// Gated like the type under test (#128). Capability/tier assertions run on any toolchain≥6.4;
// the generate/generateStructured tests are live-model by design (Apple's FoundationModels
// exposes no fake/mock session to substitute) and skip when unavailable. Registered in
// scripts/lib/live-model-tests.sh so local full runs serialize on the on-device model (#1594).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

/// `.serialized` because the live tests share the single on-device model: run concurrently
/// (Swift Testing's default) they contend for it, inflating each turn from seconds to minutes
/// (272–777s observed) and inducing transient mid-turn failures that surface as bogus assertion
/// flakes (#1378). Serialized, the same live tests complete in a fraction of the contended
/// wall-clock. The no-model tests in this suite are sub-millisecond, so serializing them too
/// costs nothing.
@Suite("FoundationModelAssistant", .serialized)
struct FoundationModelAssistantTests {

    private func makeContext() -> AssistantContext {
        AssistantContext(siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
    }

    private func modelAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Drains one live `converse` turn, returning the accumulated reply text and the terminal
    /// event. Callers must check the terminal for `.failed`: the on-device model can error
    /// transiently mid-turn (guardrails, contention, inference restarts), and a bare
    /// `for await _ in` loop swallows that silently — a dead setup turn then resurfaces later as
    /// a misleading content-assertion failure on a *different* turn (#1378).
    private func drainTurn(
        _ assistant: FoundationModelAssistant,
        prompt: String,
        context: AssistantContext
    ) async throws -> (reply: String, terminal: AssistantEvent?) {
        var reply = ""
        var last: AssistantEvent?
        for await event in try await assistant.converse(prompt: prompt, context: context) {
            if case .textDelta(let text) = event { reply += text }
            last = event
        }
        return (reply, last)
    }

    /// True when `terminal` is a transient live-model failure. Live-FM tests early-return on it
    /// (mirroring the `modelAvailable()` guard) rather than mis-reporting an environmental error
    /// as a behavioral assertion failure — these tests only ever run on dev machines (CI runners
    /// have no model), so they are integration smokes, not arbiters (#1378).
    private func isEnvironmentalFailure(_ terminal: AssistantEvent?) -> Bool {
        if case .failed = terminal { return true }
        return false
    }

    // MARK: Capabilities / tier (no model required)

    @Test("on-device tier advertises the on-device capabilities")
    func onDeviceCapabilities() {
        let caps = FoundationModelAssistant(tier: .onDevice).capabilities
        #expect(caps.providerName == "On-Device")
        #expect(caps.maxContextTokens == 4_096)
        #expect(caps.supportsStreaming)
        #expect(caps.supportsStructuredOutput)
        #expect(caps.supportsTools)  // Spotlight tool is always attached (C.8, #158)
        #expect(caps.supportsVision)  // macOS 27 on-device model accepts image attachments (C.7)
    }

    @Test("Spotlight tool is attached unconditionally, so supportsTools is true with no deps")
    func spotlightMakesToolsUnconditional() {
        // No editBridge / contentGraph supplied. SpotlightSearchTool needs neither — it queries
        // the system Core Spotlight index directly — so the session still carries a tool (C.8, #158).
        let caps = FoundationModelAssistant(tier: .onDevice, editBridge: nil, contentGraph: nil).capabilities
        #expect(caps.supportsTools)
    }

    @Test("PCC tier advertises a larger context window and PCC provider name")
    func pccCapabilities() {
        let caps = FoundationModelAssistant(tier: .privateCloudCompute).capabilities
        #expect(caps.providerName == "Private Cloud Compute")
        #expect(caps.maxContextTokens == 32_768)
    }

    @Test("default tier is on-device")
    func defaultTierIsOnDevice() {
        #expect(FoundationModelAssistant().capabilities.providerName == "On-Device")
    }

    @Test("maxRetainedTurns is clamped to at least 1, not left non-positive (#456)")
    func maxRetainedTurnsIsClamped() {
        // trimSessionIfNeeded's cutoff indexing (`promptIndices.count - maxRetainedTurns`) assumes
        // at least 1; `<= 0` would index at/past the end of `promptIndices` and crash once a turn
        // lands. `init` clamps rather than crashing.
        #expect(FoundationModelAssistant(maxRetainedTurns: 0).maxRetainedTurnsForTesting == 1)
        #expect(FoundationModelAssistant(maxRetainedTurns: -5).maxRetainedTurnsForTesting == 1)
        #expect(FoundationModelAssistant(maxRetainedTurns: 3).maxRetainedTurnsForTesting == 3)
    }

    // MARK: Design-interview chat tool (#665) — no model required

    /// Counts factory invocations from a `@Sendable` closure without data races.
    private actor InvocationCounter {
        var count = 0
        func increment() { count += 1 }
    }

    /// A design-interview factory whose inner assistant is never exercised — these tests only
    /// cover the hosting actor's lazy-build/cache/reset lifecycle, not the interview itself.
    private func makeInterviewFactory(counting counter: InvocationCounter) -> @Sendable () async -> DesignInterviewModel {
        {
            await counter.increment()
            return await MainActor.run {
                DesignInterviewModel(
                    businessType: "bakery",
                    assistant: FoundationModelAssistant(tier: .onDevice),
                    package: AnglesitePackage(url: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)),
                    siteID: "site-1"
                )
            }
        }
    }

    @Test("design-interview model is built lazily, cached across calls, and cleared by resetSession (#665)")
    func designInterviewModelLifecycle() async throws {
        let counter = InvocationCounter()
        let assistant = FoundationModelAssistant(designInterviewFactory: makeInterviewFactory(counting: counter))
        // Lazy: nothing built at init.
        #expect(await counter.count == 0)
        let first = try #require(await assistant.currentDesignInterviewModel())
        let second = try #require(await assistant.currentDesignInterviewModel())
        // Cached: one interview per chat session, not one per turn.
        #expect(first === second)
        #expect(await counter.count == 1)
        // resetSession starts a fresh interview along with the fresh chat.
        await assistant.resetSession()
        let third = try #require(await assistant.currentDesignInterviewModel())
        #expect(third !== first)
        #expect(await counter.count == 2)
    }

    @Test("no factory means no design-interview model and no advertised tool (#665)")
    func designInterviewAbsentWithoutFactory() async {
        let assistant = FoundationModelAssistant()
        #expect(await assistant.currentDesignInterviewModel() == nil)
        #expect(await !assistant.attachedToolNamesForTesting.contains(DesignInterviewTool.toolName))
    }

    @Test("a supplied factory attaches DesignInterviewTool to the conversational session (#665)")
    func designInterviewToolAttachedWithFactory() async {
        let counter = InvocationCounter()
        let assistant = FoundationModelAssistant(designInterviewFactory: makeInterviewFactory(counting: counter))
        #expect(await assistant.attachedToolNamesForTesting.contains(DesignInterviewTool.toolName))
        let tools = await assistant.conversationToolsForTesting(for: makeContext())
        #expect(tools.contains { $0 is DesignInterviewTool })
        // Attaching the tool must not eagerly build the interview model.
        #expect(await counter.count == 0)
    }

    // MARK: WYSIWYG rewrite tool (#1227 PR 2) — no model required

    @Test("no wysiwygBlockAccessProvider means no RewriteBlockTool and no advertised tool")
    func rewriteBlockAbsentWithoutProvider() async {
        let assistant = FoundationModelAssistant()
        #expect(await !assistant.attachedToolNamesForTesting.contains(RewriteBlockTool.toolName))
        let tools = await assistant.conversationToolsForTesting(for: makeContext())
        #expect(!tools.contains { $0 is RewriteBlockTool })
    }

    /// `conversationTools` attaches `RewriteBlockTool` purely on the provider's *presence*, whether
    /// or not it currently resolves to a live canvas — fix round 2 (#1227 PR 2 final review, Finding
    /// 2) moved the actual per-turn resolution into `RewriteBlockTool.call` itself (covered by
    /// `RewriteBlockToolTests`'s `repliesCanvasNotOpenWhenProviderResolvesNil`), because the cached,
    /// multi-turn `LanguageModelSession` reuses tool instances across turns — resolving inside
    /// `conversationTools`, as fix round 1 did, only takes effect when a session is rebuilt, not on
    /// every turn of an already-cached conversation.
    @Test("attachedToolNames and conversationTools both report the provider is wired, independent of what it currently resolves to")
    func rewriteBlockAdvertisedWheneverProviderSupplied() async {
        let assistant = FoundationModelAssistant(wysiwygBlockAccessProvider: { nil })
        #expect(await assistant.attachedToolNamesForTesting.contains(RewriteBlockTool.toolName))
        let tools = await assistant.conversationToolsForTesting(for: makeContext())
        #expect(tools.contains { $0 is RewriteBlockTool })
    }

    @Test("PCC-tier assistant constructs and remains usable (falls back to on-device)")
    func pccConstructsAndIsUsable() {
        // `capabilities` is a nonisolated var, so it reads synchronously off the actor.
        let assistant = FoundationModelAssistant(tier: .privateCloudCompute)
        #expect(assistant.capabilities.maxContextTokens == 32_768)
    }

    // MARK: Error path (meaningful only on a host WITHOUT the model)

    @Test("generate surfaces AssistantError.unavailable when the model is absent")
    func generateUnavailableSurfacesError() async {
        guard !modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        do {
            _ = try await assistant.generate(prompt: "hi", context: makeContext())
            Issue.record("Expected AssistantError.unavailable but generate succeeded")
        } catch let error as AssistantError {
            guard case .unavailable = error else {
                Issue.record("Expected AssistantError.unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected non-AssistantError: \(error)")
        }
    }

    // MARK: Live paths (skip when the model is unavailable)

    @Test("generate streams non-empty text")
    func generateStreamsText() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var collected = ""
        for try await chunk in try await assistant.generate(prompt: "Say hello in one short sentence.", context: makeContext()) {
            collected += chunk
        }
        #expect(!collected.isEmpty)
    }

    @Test("abandoning a generate stream mid-generation drains without trapping (#201)")
    func abandonGenerateMidStreamDoesNotTrap() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        // Repeatedly drop the stream after the first chunk while the model is still producing. Before
        // #201 this fired `task.cancel()` in `onTermination`, cancelling `streamResponse` mid-iteration
        // and trapping the process (`brk 1`, signal 5); the drain-and-detach fix lets it finish in the
        // background. The trap is timing-dependent, so loop to make the regression reliable to catch —
        // against the buggy code this crashes within a handful of iterations.
        for _ in 0..<10 {
            for try await _ in try await assistant.generate(
                prompt: "Write a long, detailed, multi-paragraph history of typography.",
                context: makeContext()
            ) {
                break
            }
        }
        // Give the abandoned background drains time to keep iterating the model stream — if an early
        // teardown still cancelled one, the trap would crash the test process rather than survive.
        try await Task.sleep(for: .seconds(1))
    }

    @Test("generateStructured returns the requested Generable type")
    func generateStructuredReturnsType() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let result = try await assistant.generateStructured(
            prompt: "Generate page metadata for a contact page.",
            context: makeContext(),
            resultType: GeneratedPageMeta.self
        )
        #expect(!result.title.isEmpty)
    }

    @Test("generateStructured(imageURL:) describes an image into GeneratedAltText")
    func generateStructuredFromImage() async throws {
        guard modelAvailable() else { return }
        let imageURL = try Self.makeTempImage()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let assistant = FoundationModelAssistant()
        // Proves the image→guided-generation path runs end-to-end. Exact content is model-dependent;
        // the contract is that it returns a valid `GeneratedAltText` (decorative ⇒ empty alt).
        let alt = try await assistant.generateStructured(
            prompt: "Generate concise alt text for this image.",
            imageURL: imageURL,
            context: makeContext(),
            resultType: GeneratedAltText.self
        )
        // Only the non-decorative case requires text: AltTextGenerator writes alt="" for a
        // decorative image regardless of `altText`, so whether the model also empties `altText`
        // (its @Guide asks, but guided generation doesn't guarantee it) is not part of the
        // contract this path depends on.
        if !alt.isDecorative {
            #expect(!alt.altText.isEmpty)
        }
    }

    /// Writes a small two-color PNG to a temp file so the vision path has a real image to read.
    private static func makeTempImage() throws -> URL {
        let side = 64
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AltTextImageError.context }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        guard let image = ctx.makeImage() else { throw AltTextImageError.render }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alttext-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw AltTextImageError.destination }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AltTextImageError.write }
        return url
    }

    private enum AltTextImageError: Error { case context, render, destination, write }

    // MARK: ConversationalAssistant conformance (C.9 — MAS chat backend)

    @Test("is usable as any ConversationalAssistant")
    func conformsToConversationalAssistant() {
        // Compile-time + runtime proof that the on-device assistant can back `ChatModel`,
        // whose dependency is `any ConversationalAssistant`.
        let assistant: any ConversationalAssistant = FoundationModelAssistant(tier: .onDevice)
        #expect(assistant.capabilities.providerName == "On-Device")
    }

    @Test("resetSession discards the cached session and is safe when none is cached")
    func resetSessionIsSafe() async {
        let assistant = FoundationModelAssistant()
        await assistant.resetSession()  // no turn in flight, no session cached yet — must be harmless
    }

    @Test("cancel with no active turn is a safe no-op")
    func cancelWithoutTurnIsSafe() async {
        let assistant = FoundationModelAssistant()
        await assistant.cancel()  // nothing in flight — must be harmless
    }

    @Test("converse surfaces AssistantError.unavailable when the model is absent")
    func converseUnavailableSurfacesError() async {
        guard !modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        do {
            _ = try await assistant.converse(prompt: "hi", context: makeContext())
            Issue.record("Expected AssistantError.unavailable but converse succeeded")
        } catch let error as AssistantError {
            guard case .unavailable = error else {
                Issue.record("Expected AssistantError.unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected non-AssistantError: \(error)")
        }
    }

    @Test("converse opens with .started, streams .textDelta, and ends with .turnComplete")
    func converseEmitsLifecycleEvents() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(
            prompt: "Say hello in one short sentence.",
            context: makeContext()
        ) {
            events.append(event)
        }

        // First event is the turn marker.
        guard case .started = events.first else {
            Issue.record("Expected first event to be .started, got \(String(describing: events.first))")
            return
        }
        // At least one text chunk arrived.
        let deltas = events.filter { if case .textDelta = $0 { return true } else { return false } }
        #expect(!deltas.isEmpty)
        // Terminal event is .turnComplete (no in-band failure).
        guard case .turnComplete = events.last else {
            Issue.record("Expected last event to be .turnComplete, got \(String(describing: events.last))")
            return
        }
    }

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
        // `guard case` rather than `#expect`: matching a non-equatable associated-value enum case
        // on an `Optional` is awkward with `#expect`; this mirrors the other converse lifecycle
        // tests in this suite (e.g. `converseEmitsLifecycleEvents`).
        guard case .turnComplete = events.last else {
            Issue.record("Expected .turnComplete (budget fit), got \(String(describing: events.last))")
            return
        }
    }

    @Test("converse retains conversation history across turns")
    func converseRemembersAcrossTurns() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        let context = makeContext()

        // Turn 1: plant a fact. Drain the stream fully so the turn completes.
        for await _ in try await assistant.converse(
            prompt: "Remember this code word: Falkor. Reply with just 'ok'.",
            context: context
        ) {}

        // Turn 2: recall is only possible if the session (and its history) persisted across turns —
        // the bug this guards against created a fresh, memoryless session per turn.
        var reply = ""
        for await event in try await assistant.converse(
            prompt: "What is the code word I gave you? Reply with only the word.",
            context: context
        ) {
            if case .textDelta(let text) = event { reply += text }
        }
        #expect(reply.localizedCaseInsensitiveContains("Falkor"))
    }

    // MARK: Page context budget / placement (#457, pure — no model required)

    @Test("conversational-session instructions never contain page route or content")
    func conversationalInstructionsOmitPageContext() {
        let context = AssistantContext(
            siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            currentPageRoute: "/about",
            currentPageContent: "Some page body text."
        )
        let instructions = FoundationModelAssistant.instructions(for: context, includePageContext: false)
        #expect(!instructions.contains("/about"))
        #expect(!instructions.contains("Some page body text."))
    }

    @Test("one-shot instructions still carry page route/content (EditInterpreter/AltTextGenerator rely on this)")
    func oneShotInstructionsIncludePageContext() {
        let context = AssistantContext(
            siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            currentPageRoute: "/about",
            currentPageContent: "Some page body text."
        )
        let instructions = FoundationModelAssistant.instructions(for: context, includePageContext: true)
        #expect(instructions.contains("/about"))
        #expect(instructions.contains("Some page body text."))
    }

    @Test("page content over the character budget is truncated")
    func pageContentIsTruncated() {
        let longContent = String(repeating: "x", count: FoundationModelAssistant.maxPageContentCharacters + 500)
        let truncated = FoundationModelAssistant.truncatedPageContent(longContent)
        #expect(truncated.count <= FoundationModelAssistant.maxPageContentCharacters + 1)  // +1 for the "…" marker
        #expect(truncated.hasSuffix("…"))
    }

    @Test("page content under the character budget passes through unchanged")
    func shortPageContentIsUnchanged() {
        let short = "just a short page"
        #expect(FoundationModelAssistant.truncatedPageContent(short) == short)
    }

    @Test("turnPrompt composes route + truncated content + the user's prompt, in order")
    func turnPromptComposesContext() {
        let context = AssistantContext(
            siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            currentPageRoute: "/about",
            currentPageContent: "Some page body text."
        )
        let composed = FoundationModelAssistant.turnPrompt(for: "What does this page say?", context: context)
        #expect(composed.contains("/about"))
        #expect(composed.contains("Some page body text."))
        #expect(composed.hasSuffix("What does this page say?"))
    }

    @Test("turnPrompt with no page context is just the prompt")
    func turnPromptWithoutContextIsBare() {
        let context = makeContext()  // no currentPageRoute/currentPageContent
        #expect(FoundationModelAssistant.turnPrompt(for: "hello", context: context) == "hello")
    }

    @Test("converse reflects a navigated page's context on the very next turn, without a session reset (#457)")
    func converseReflectsUpdatedContextPerTurn() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()

        // Turn 1: no page context.
        let (_, setupTerminal) = try await drainTurn(assistant, prompt: "Reply with just 'ok'.", context: makeContext())
        if isEnvironmentalFailure(setupTerminal) { return }

        // Turn 2: the user "navigated" — a fresh AssistantContext carries new page content, with no
        // resetSession() call in between. The cached session's *instructions* were fixed at turn 1
        // (before this page existed), so this only works if the content rides on the turn's prompt.
        let navigatedContext = AssistantContext(
            siteID: "site-1",
            siteDirectory: URL(fileURLWithPath: "/tmp/site"),
            currentPageContent: "The secret ingredient is saffron."
        )
        let (reply, terminal) = try await drainTurn(
            assistant,
            prompt: "What is the secret ingredient mentioned in the current page content? Reply with only the word.",
            context: navigatedContext
        )
        if isEnvironmentalFailure(terminal) { return }
        let replyHasIngredient = reply.localizedCaseInsensitiveContains("saffron")
        #expect(replyHasIngredient)
    }

    @Test("converse trims the cached session's transcript once it exceeds the retained-turn budget (#456)")
    func converseTrimsTranscriptBeyondBudget() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant(maxRetainedTurns: 2)
        let context = makeContext()

        for turn in 1...4 {
            let prompt = turn == 3
                ? "Remember this code word: Falkor. Reply with just 'ok'."
                : "Reply with just 'ok'."
            let (_, terminal) = try await drainTurn(assistant, prompt: prompt, context: context)
            if isEnvironmentalFailure(terminal) { return }
        }

        // Four turns landed but the retained-turn budget is 2 — the cached session must have been
        // rebuilt from a trimmed window rather than growing unbounded.
        let promptCount = await assistant.promptCountForTesting
        #expect(promptCount != nil)
        if let promptCount { #expect(promptCount <= 2) }

        // The trimmed window keeps the *most recent* turns: turn 3's code word must still be in
        // the retained transcript (deterministic — this is #456's actual contract, independent of
        // how the live model phrases anything).
        let retained = await assistant.transcriptTextForTesting
        let retainedHasCodeWord = retained?.localizedCaseInsensitiveContains("Falkor") ?? false
        #expect(retainedHasCodeWord)

        // Live-model layer: the code word must also be *recoverable* — but the reply's exact
        // wording is not stable, because the session's always-attached Spotlight tool tempts the
        // model into a search loop ("**=\"Falkor\"cdw") after which its prose sometimes paraphrases
        // without repeating the word (#1378). Accept the word in the reply *or* anywhere in the
        // post-turn transcript: after this turn's own trim, the only surviving entries that can
        // contain it are ones the model itself produced (tool-call arguments or the response), so
        // the fallback still proves recall rather than echoing turn 3's planted prompt.
        let (reply, recallTerminal) = try await drainTurn(
            assistant,
            prompt: "What is the code word I gave you? Reply with only the word.",
            context: context
        )
        if isEnvironmentalFailure(recallTerminal) { return }
        let replyHasCodeWord = reply.localizedCaseInsensitiveContains("Falkor")
        let postRecallTranscript = await assistant.transcriptTextForTesting
        let modelEchoedCodeWord = postRecallTranscript?.localizedCaseInsensitiveContains("Falkor") ?? false
        #expect(replyHasCodeWord || modelEchoedCodeWord)
    }

    @Test("converse proactively trims once the transcript's estimated weight nears budget, even below maxRetainedTurns (#657)")
    func converseProactivelyTrimsOverTokenBudget() async throws {
        guard modelAvailable() else { return }
        // maxRetainedTurns is high enough that the existing turn-count trim (#456) would never
        // fire within this test — any shrinkage observed here is attributable only to the
        // token-budget check added for #657.
        let assistant = FoundationModelAssistant(maxRetainedTurns: 50)
        let context = makeContext()

        // Plant several bulky-but-bounded turns. Each is well within the real on-device budget on
        // its own, but their combined weight (plus the always-attached Spotlight tool schema)
        // crosses the proactive threshold well before 50 turns land — the #657 scenario, where a
        // heavy attached tool set left little headroom for even a handful of turns.
        let bulky = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 150)
            + " Reply with just 'ok'."
        for _ in 1...3 {
            let (_, terminal) = try await drainTurn(assistant, prompt: bulky, context: context)
            if isEnvironmentalFailure(terminal) { return }
        }

        // Without the proactive trim, this turn would extend an already-near-budget transcript and
        // risk the hard "transcript exceeded the model's context size" failure reported in #657.
        // With it, the cached session is shrunk *before* this turn runs, so it still completes.
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "Reply with just 'ok'.", context: context) {
            events.append(event)
        }
        guard case .turnComplete = events.last else {
            Issue.record("Expected .turnComplete (proactive trim kept the turn within budget), got \(String(describing: events.last))")
            return
        }

        // The count-based ceiling (50) was never reached, so any window smaller than the 4 turns
        // submitted is attributable only to the token-budget check.
        let promptCount = await assistant.promptCountForTesting
        #expect(promptCount != nil)
        if let promptCount { #expect(promptCount < 4) }
    }

    @Test("cancel mid-stream yields .cancelled and ends the turn")
    func cancelMidStreamYieldsCancelled() async throws {
        guard modelAvailable() else { return }
        let assistant = FoundationModelAssistant()
        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(
            prompt: "Write a long, detailed, multi-paragraph history of typography.",
            context: makeContext()
        ) {
            events.append(event)
            // Cancel as soon as the model starts emitting text — the turn must wind down to
            // `.cancelled`, not run to `.turnComplete`.
            if case .textDelta = event { await assistant.cancel() }
        }
        switch events.last {
        case .cancelled:
            break  // Cancel landed mid-stream and terminated the turn — the asserted path.
        case .turnComplete:
            // Benign race, not a cancellation bug (#1378): the model delivered its whole reply as
            // already-buffered snapshot(s), so `.turnComplete` was enqueued behind the first
            // `.textDelta` before this loop's body could call `cancel()` — and cancel after a turn
            // ends is a documented no-op. `TurnRelay`'s once-only terminal transition guarantees
            // `.cancelled` wins whenever cancel lands first; that deterministic contract is covered
            // by TurnRelayTests, so nothing is asserted on this interleaving here.
            break
        case .failed:
            // Transient live-model error ended the turn before cancellation could be exercised —
            // environmental, same early-return treatment as the setup turns above (#1378).
            break
        default:
            Issue.record("Expected last event to be .cancelled, got \(String(describing: events.last))")
        }
    }
}
#endif
