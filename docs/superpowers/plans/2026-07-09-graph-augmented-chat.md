# Free-form cross-node site Q&A (#314) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Chat panel answer free-form, cross-node questions about how the site is built ("How is navigation generated?", "Why is this image appearing here?"), grounded in the site's dependency graph, with clickable citations that reveal the matching node in the Site Graph Explorer.

**Architecture:** Add `SiteGraphAugmentedAssistant`, a new `ConversationalAssistant` decorator in `AnglesiteCore` that mirrors the existing `KnowledgeAugmentedAssistant` content-RAG pattern but grounds on the Site Graph Explorer's already-live `SiteGraphExplorerSnapshot` (nodes/edges + `ImpactAnalysis.Report`) instead of file text. Wire it into the existing per-site assistant chain in `SiteAssistantSessionFactory`, and extend the existing citation-chip UI so a click reveals the node in the Site Graph Explorer when possible, falling back to opening the file.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`), SwiftUI, FoundationModels (gated `#if compiler(>=6.4)`).

## Global Constraints

- On-device Foundation Models only, no network fallback (LLM policy, #459) — this plan adds no new model calls; it only changes what gets prepended to the prompt `FoundationModelAssistant` already sends.
- Every statement in an answer must be traceable to a cited source file (issue #314) — enforced by only injecting facts for nodes with a resolvable path, and instructing the model to cite them.
- Follow the existing decorator pattern (`KnowledgeAugmentedAssistant`) rather than agentic tool-calling — tool-call results have no capture hook today (`FoundationModelAssistant.swift:229-230`), so front-loaded retrieval is the only path that can produce citations.
- `SiteGraphExplainPrompt`'s existing single-node behavior (#614) must not change — `SiteGraphExplainPromptTests` must keep passing unchanged after the refactor in Task 1.

---

### Task 1: Extract `SiteGraphExplainPrompt.facts(...)` for reuse

**Files:**
- Modify: `Sources/AnglesiteCore/SiteGraphNodeExplainer.swift:40-72`
- Test: `Tests/AnglesiteCoreTests/SiteGraphExplainPromptTests.swift` (existing — must keep passing unchanged)

**Interfaces:**
- Produces: `SiteGraphExplainPrompt.facts(node: SiteGraphNode, impact: ImpactAnalysis.Report, dependsOn: [SiteGraphNode], referencedBy: [SiteGraphNode]) -> [String]` — used by Task 2's `SiteGraphAugmentedAssistant`.

This is a pure refactor (extract a helper, no behavior change), so the "test" step is confirming the existing characterization tests still pass before and after.

- [ ] **Step 1: Run the existing tests to establish a passing baseline**

Run: `swift test --filter SiteGraphExplainPrompt`
Expected: PASS (all 8 tests in `SiteGraphExplainPromptTests`)

- [ ] **Step 2: Extract the fact-building body into `facts(...)`**

In `Sources/AnglesiteCore/SiteGraphNodeExplainer.swift`, replace the existing `prompt(...)` method (lines 40-72) with:

```swift
    static func facts(
        node: SiteGraphNode,
        impact: ImpactAnalysis.Report,
        dependsOn: [SiteGraphNode],
        referencedBy: [SiteGraphNode]
    ) -> [String] {
        // A neighbor reachable through several edge kinds (e.g. both `imports` and `usesLayout`)
        // arrives once per edge — list it once, or the capped fact list fills with duplicates.
        let uniqueDependsOn = deduplicated(dependsOn)
        let uniqueReferencedBy = deduplicated(referencedBy)
        var facts: [String] = []
        facts.append("- This file: \(node.title) (a \(kindLabel(node.kind)) on the site)")
        if let route = node.route { facts.append("- Its page address: \(route)") }
        if let filePath = node.filePath { facts.append("- Its source file: \(filePath)") }
        if !uniqueDependsOn.isEmpty {
            facts.append("- Depends on: \(nameList(uniqueDependsOn, withKinds: true))")
        }
        if !uniqueReferencedBy.isEmpty {
            facts.append("- Referenced by: \(nameList(uniqueReferencedBy, withKinds: true))")
        }
        facts.append(contentsOf: impactFacts(impact))
        return facts
    }

    public static func prompt(
        node: SiteGraphNode,
        impact: ImpactAnalysis.Report,
        dependsOn: [SiteGraphNode],
        referencedBy: [SiteGraphNode]
    ) -> String {
        let factLines = facts(node: node, impact: impact, dependsOn: dependsOn, referencedBy: referencedBy)
        return """
        You are explaining one file in a static website's dependency graph to the site's owner, \
        who is not a developer. Using only the facts below, write a short plain-language \
        explanation (2 to 4 sentences) of this file's role on the site and what editing it would \
        affect. Do not invent details that are not in the facts, and do not repeat the facts as a \
        list — synthesize them.

        Facts:
        \(factLines.joined(separator: "\n"))
        """
    }
```

`facts` is deliberately not `public` — its only consumer (Task 2's `SiteGraphAugmentedAssistant`) lives in the same `AnglesiteCore` module.

- [ ] **Step 3: Run the tests again to confirm no regression**

Run: `swift test --filter SiteGraphExplainPrompt`
Expected: PASS (same 8 tests, unchanged assertions, unchanged output)

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/SiteGraphNodeExplainer.swift
git commit -m "refactor: extract SiteGraphExplainPrompt.facts for reuse (#314)"
```

---

### Task 2: `SiteGraphAugmentedAssistant` — graph-grounded RAG decorator

**Files:**
- Create: `Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/SiteGraphAugmentedAssistantTests.swift`

**Interfaces:**
- Consumes: `SiteGraphExplainPrompt.facts(node:impact:dependsOn:referencedBy:) -> [String]` (Task 1), `ImpactAnalysis.analyze(snapshot:targetID:) -> Report?`, `SiteGraphExplorerSnapshot`/`SiteGraphNode`/`SiteGraphNodeKind`, `RetrievedCitation`, `ConversationalAssistant`/`AssistantContext`/`AssistantEvent`.
- Produces: `public actor SiteGraphAugmentedAssistant: ConversationalAssistant`, `public init(base: any ConversationalAssistant, snapshotProvider: @escaping @Sendable () async -> SiteGraphExplorerSnapshot)` — consumed by Task 3's `SiteAssistantSessionFactory`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SiteGraphAugmentedAssistantTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4)
import FoundationModels
#endif

private actor CapturingConversationalAssistant: ConversationalAssistant {
    private(set) var prompts: [String] = []

    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Capture"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        prompts.append(prompt)
        return AsyncStream { continuation in
            continuation.yield(.started(model: "Capture", toolNames: []))
            continuation.yield(.textDelta("ok"))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        prompts.append(prompt)
        throw AssistantError.unsupported("capture assistant does not generate structured values")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}

@Suite("SiteGraphAugmentedAssistant")
struct SiteGraphAugmentedAssistantTests {
    private func node(
        _ id: String,
        kind: SiteGraphNodeKind = .component,
        title: String,
        route: String? = nil,
        filePath: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: kind, title: title, detail: nil, filePath: filePath, route: route)
    }

    private var context: AssistantContext {
        AssistantContext(siteID: "site", siteDirectory: FileManager.default.temporaryDirectory)
    }

    @Test("converse grounds the prompt in a matching node's facts and cites its file")
    func converseGroundsMatchingNode() async throws {
        let header = node("c1", kind: .component, title: "Header", filePath: "src/components/Header.astro")
        let home = node("p1", kind: .page, title: "Home", route: "/", filePath: "src/pages/index.astro")
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [header, home],
            edges: [SiteGraphEdge(sourceID: "p1", targetID: "c1", kind: .imports)]
        )
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "How does the Header work?", context: context) {
            events.append(event)
        }

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/Header.astro") == true)
        #expect(prompt?.contains("User request:\nHow does the Header work?") == true)

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected first event to be .citations, got \(events.first.debugDescription)")
            return
        }
        #expect(citations.count == 1)
        #expect(citations.first?.path == "src/components/Header.astro")
        #expect(citations.first?.kind == .component)
    }

    @Test("converse with no matching node skips citations and leaves the prompt untouched")
    func converseNoMatchLeavesPromptUntouched() async throws {
        let header = node("c1", kind: .component, title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })
        let prompt = "Explain quantum entanglement"

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: prompt, context: context) {
            events.append(event)
        }

        #expect(await base.prompts.first == prompt)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }

    @Test("seed nodes are capped at 3, ranked by number of matched terms")
    func seedNodesCappedAndRanked() async throws {
        let exactMatch = node("c1", title: "Contact Form", filePath: "src/components/ContactForm.astro")
        let partial1 = node("c2", title: "Contact Widget", filePath: "src/components/ContactWidget.astro")
        let partial2 = node("c3", title: "Contact Banner", filePath: "src/components/ContactBanner.astro")
        let extra = node("c4", title: "Contact Footer", filePath: "src/components/ContactFooter.astro")
        let unrelated = node("c5", title: "Newsletter Signup", filePath: "src/components/Newsletter.astro")
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [exactMatch, partial1, partial2, extra, unrelated],
            edges: []
        )
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "Where is the contact form?", context: context) {
            events.append(event)
        }

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected .citations event")
            return
        }
        #expect(citations.count == 3)
        #expect(!citations.contains { $0.path == "src/components/Newsletter.astro" })
    }

    @Test("a node with no file path is used for grounding but not cited")
    func nodeWithoutFilePathNotCited() async throws {
        let collection = node("col1", kind: .collection, title: "Blog Collection")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [collection], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "What is the Blog Collection?", context: context) {
            events.append(event)
        }

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Blog Collection") == true)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }

    @Test("generate also grounds the prompt, matching converse")
    func generateGroundsPrompt() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        for try await _ in try await assistant.generate(prompt: "Tell me about the Header", context: context) {}

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SiteGraphAugmentedAssistant`
Expected: FAIL with "cannot find 'SiteGraphAugmentedAssistant' in scope" (the type doesn't exist yet)

- [ ] **Step 3: Implement `SiteGraphAugmentedAssistant`**

Create `Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift`:

```swift
import Foundation

#if compiler(>=6.4)
import FoundationModels
#endif

/// Free-form, cross-node grounding for the Chat panel (#314). Mirrors
/// ``KnowledgeAugmentedAssistant``'s content-search enrichment, but grounds on the Site Graph
/// Explorer's dependency graph and ``ImpactAnalysis`` instead of file text — the facts needed to
/// answer structural questions ("how is navigation generated", "why does this image appear
/// here") that a text search over file contents can't answer.
///
/// Reuses #614's per-node fact list (``SiteGraphExplainPrompt/facts(node:impact:dependsOn:referencedBy:)``)
/// for up to ``SiteGraphAugmentedAssistant/maxSeedNodes`` nodes matched against the question's
/// words. Contributes nothing when no node matches, so unrelated chat turns are unaffected.
public actor SiteGraphAugmentedAssistant: ConversationalAssistant {
    /// Largest number of matched nodes to ground a single question in — keeps the prompt within
    /// the small on-device context window, matching the philosophy of
    /// `SiteGraphExplainPrompt.maxListedNames`.
    static let maxSeedNodes = 3

    private let base: any ConversationalAssistant
    private let snapshotProvider: @Sendable () async -> SiteGraphExplorerSnapshot

    public init(
        base: any ConversationalAssistant,
        snapshotProvider: @escaping @Sendable () async -> SiteGraphExplorerSnapshot
    ) {
        self.base = base
        self.snapshotProvider = snapshotProvider
    }

    public nonisolated var capabilities: AssistantCapabilities {
        base.capabilities
    }

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let (enriched, citations) = await enrichedContext(prompt)
        let baseStream = try await base.converse(prompt: enriched, context: context)
        guard !citations.isEmpty else { return baseStream }
        // Prepended ahead of whatever `base` itself yields — if `base` is a
        // `KnowledgeAugmentedAssistant`, its own `.citations` event (content-search sources)
        // still arrives afterward as a second, separate "Sources" row. That's an accepted UX
        // trade-off: two decorators, each contributing citations independently, is simpler and
        // more honest than guessing how to merge two different kinds of retrieval.
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.citations(citations))
                for await event in baseStream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let (enriched, _) = await enrichedContext(prompt)
        return try await base.generate(prompt: enriched, context: context)
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let (enriched, _) = await enrichedContext(prompt)
        return try await base.generateStructured(prompt: enriched, context: context, resultType: resultType)
    }
    #endif

    public func cancel() async {
        await base.cancel()
    }

    public func resetSession() async {
        await base.resetSession()
    }

    private func enrichedContext(_ prompt: String) async -> (prompt: String, citations: [RetrievedCitation]) {
        let snapshot = await snapshotProvider()
        let seeds = Self.seedNodes(for: prompt, in: snapshot)
        guard !seeds.isEmpty else { return (prompt, []) }

        var blocks: [String] = []
        var citations: [RetrievedCitation] = []
        for node in seeds {
            guard let impact = ImpactAnalysis.analyze(snapshot: snapshot, targetID: node.id) else { continue }
            let (dependsOn, referencedBy) = Self.neighbors(of: node, in: snapshot)
            let facts = SiteGraphExplainPrompt.facts(node: node, impact: impact, dependsOn: dependsOn, referencedBy: referencedBy)
            blocks.append("Facts about \(node.title):\n" + facts.joined(separator: "\n"))
            if let citation = Self.citation(for: node) { citations.append(citation) }
        }
        guard !blocks.isEmpty else { return (prompt, []) }

        let enriched = """
        You are answering a question about how this Astro website is built, using only the \
        facts below about specific files in its dependency graph. Do not invent details that \
        are not in the facts, and cite file paths when you use a fact.

        \(blocks.joined(separator: "\n\n"))

        User request:
        \(prompt)
        """
        return (enriched, citations)
    }

    /// Scores every node's title/route/filePath against the question's words (case-insensitive
    /// substring match, matching `SiteKnowledgeIndex`'s keyword-search style rather than
    /// embeddings), and returns the top ``maxSeedNodes`` by match count. Ties break by title
    /// (matching `ImpactAnalysis`'s stable sort), then id.
    static func seedNodes(for question: String, in snapshot: SiteGraphExplorerSnapshot) -> [SiteGraphNode] {
        let terms = queryTerms(question)
        guard !terms.isEmpty else { return [] }
        let scored: [(node: SiteGraphNode, score: Int)] = snapshot.nodes.compactMap { node in
            let score = matchScore(node: node, terms: terms)
            return score > 0 ? (node, score) : nil
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let byTitle = lhs.node.title.localizedStandardCompare(rhs.node.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return lhs.node.id < rhs.node.id
            }
            .prefix(maxSeedNodes)
            .map(\.node)
    }

    /// Direct neighbors of `node` (one hop each direction), matching what #614's
    /// `SiteGraphExplorerModel.explainSelectedNode()` computes for the single-node case.
    static func neighbors(
        of node: SiteGraphNode,
        in snapshot: SiteGraphExplorerSnapshot
    ) -> (dependsOn: [SiteGraphNode], referencedBy: [SiteGraphNode]) {
        let nodesByID = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var dependsOn: [SiteGraphNode] = []
        var referencedBy: [SiteGraphNode] = []
        for edge in snapshot.edges {
            if edge.sourceID == node.id, let target = nodesByID[edge.targetID] { dependsOn.append(target) }
            if edge.targetID == node.id, let source = nodesByID[edge.sourceID] { referencedBy.append(source) }
        }
        return (dependsOn, referencedBy)
    }

    /// `nil` when the node has no file path (e.g. a `.collection` node, which represents a
    /// grouping rather than a single file) — it still grounds the answer via its facts block,
    /// but there is nothing sensible to cite or open.
    static func citation(for node: SiteGraphNode) -> RetrievedCitation? {
        guard let path = node.filePath else { return nil }
        return RetrievedCitation(
            id: node.id,
            path: path,
            kind: documentKind(for: node.kind),
            title: node.title,
            lineRange: nil,
            score: 1
        )
    }

    static func documentKind(for kind: SiteGraphNodeKind) -> SiteKnowledgeIndex.Document.Kind {
        switch kind {
        case .page: return .page
        case .layout: return .layout
        case .component: return .component
        case .collection, .contentEntry: return .content
        case .asset: return .other
        case .style: return .style
        }
    }

    private static func matchScore(node: SiteGraphNode, terms: [String]) -> Int {
        let haystack = [node.title, node.route, node.filePath]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return terms.reduce(0) { count, term in haystack.contains(term) ? count + 1 : count }
    }

    /// Words of 3+ characters — short words ("is", "the", "of") match nearly every node and add
    /// noise rather than signal.
    private static func queryTerms(_ question: String) -> [String] {
        question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SiteGraphAugmentedAssistant`
Expected: PASS (all 5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift Tests/AnglesiteCoreTests/SiteGraphAugmentedAssistantTests.swift
git commit -m "feat: add SiteGraphAugmentedAssistant, graph-grounded RAG for chat (#314)"
```

---

### Task 3: Wire `SiteGraphAugmentedAssistant` into the per-site assistant chain

**Files:**
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:1104-1114`
- Test: `Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift` (new)

**Interfaces:**
- Consumes: `SiteGraphAugmentedAssistant.init(base:snapshotProvider:)` (Task 2), `SiteWindowModel.graphExplorer.snapshot` (existing, `Sources/AnglesiteApp/SiteGraphExplorerModel.swift:22`).
- Produces: `SiteAssistantSessionFactory.makeSession(..., graphSnapshotProvider:)` — the new required parameter every call site must supply.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Actor-based capture, not a plain `var` mutated inside `Task { }` — the assistant-builder
/// closure runs synchronously but needs to await the (async) snapshot provider, so the capture
/// itself must be safe to mutate from that detached `Task`. Matches the `CapturingConversationalAssistant`
/// idiom already used in `KnowledgeAugmentedAssistantTests`.
private actor SnapshotCapture {
    private(set) var received: SiteGraphExplorerSnapshot?
    func capture(_ snapshot: SiteGraphExplorerSnapshot) { received = snapshot }
}

@Suite("SiteAssistantSessionFactory")
@MainActor
struct SiteAssistantSessionFactoryTests {
    @Test("makeSession forwards the graph snapshot provider to the assistant builder")
    func forwardsGraphSnapshotProvider() async throws {
        let expected = SiteGraphExplorerSnapshot(
            nodes: [SiteGraphNode(id: "n1", kind: .page, title: "Home", detail: nil, filePath: "src/pages/index.astro", route: "/")],
            edges: []
        )
        let capture = SnapshotCapture()
        var dependencies = SiteAssistantSessionFactory.Dependencies.live
        dependencies.assistant = { _, _, _, _, _, graphSnapshotProvider in
            Task {
                let snapshot = await graphSnapshotProvider()
                await capture.capture(snapshot)
            }
            return StubConversationalAssistant()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            mcpClient: { nil },
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: nil,
            integrationService: IntegrationOperations.live(),
            dependencies: dependencies,
            graphSnapshotProvider: { expected }
        )

        while await capture.received == nil { await Task.yield() }
        #expect(await capture.received == expected)
    }
}

private actor StubConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
            supportsTools: false, maxContextTokens: nil, providerName: "Stub"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        AsyncStream { $0.finish() }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("stub")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}
```

Note: if `IntegrationOperations.live()` or `ProjectConventionsEngine` construction requires arguments this test doesn't have handy, check their existing usages in `SiteWindowModelTests.swift` (`ProjectConventionsEngine()`) and reuse the same no-argument/lightweight construction — `conventionsEngine` in `makeSession` is optional (`ProjectConventionsEngine?`) per the factory's parameter list read in Task 3 Step 2 below, so passing `nil` there is valid.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SiteAssistantSessionFactoryTests`
Expected: FAIL to compile — `makeSession` has no `graphSnapshotProvider:` parameter and `Dependencies.assistant`'s closure type has no 6th parameter yet.

- [ ] **Step 3: Update `SiteAssistantSessionFactory`**

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, replace the `AssistantBuilder` typealias (line 18-24) with:

```swift
    typealias GraphSnapshotProvider = @Sendable () async -> SiteGraphExplorerSnapshot
    typealias AssistantBuilder = @Sendable (
        _ editBridge: IntentEditBridge,
        _ contentGraph: SiteContentGraph,
        _ knowledgeIndex: SiteKnowledgeIndex,
        _ semanticRanker: SemanticRanker?,
        _ integrationService: any IntegrationOperationsService,
        _ graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> any ConversationalAssistant
```

Replace the `assistant` closure inside `Dependencies.live` (lines 52-64) with:

```swift
            let assistant: AssistantBuilder = { editBridge, contentGraph, knowledgeIndex, semanticRanker, integrationService, graphSnapshotProvider in
                SiteGraphAugmentedAssistant(
                    base: KnowledgeAugmentedAssistant(
                        base: FoundationModelAssistant(
                            tier: .onDevice,
                            editBridge: editBridge,
                            contentGraph: contentGraph,
                            knowledgeIndex: knowledgeIndex,
                            semanticRanker: semanticRanker,
                            integrationService: integrationService
                        ),
                        index: knowledgeIndex
                    ),
                    snapshotProvider: graphSnapshotProvider
                )
            }
```

Replace `makeSession`'s signature and body (lines 108-137) with:

```swift
    static func makeSession(
        siteID: String,
        sourceDirectory: URL,
        configDirectory: URL,
        mcpClient: @escaping MCPClientProvider,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?,
        integrationService: any IntegrationOperationsService,
        dependencies: Dependencies = .live,
        graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> SiteAssistantSession {
        let editBridge = IntentEditBridge(routerProvider: dependencies.editRouterProvider)
        let chat = ChatModel(
            siteID: siteID,
            siteDirectory: sourceDirectory,
            configDirectory: configDirectory,
            assistant: dependencies.assistant(
                editBridge,
                contentGraph,
                knowledgeIndex,
                semanticRanker,
                integrationService,
                graphSnapshotProvider
            ),
            annotationFeed: dependencies.annotationFeed(sourceDirectory),
            annotationResolver: { [resolveAnnotation = dependencies.resolveAnnotation] id in
                try await resolveAnnotation(sourceDirectory, id)
            },
            undoCommand: dependencies.undoCommand(mcpClient)
        )

        let altTextGenerator = dependencies.altTextGenerator(siteID, sourceDirectory, mcpClient, conventionsEngine)
        let postProcessor: MCPApplyEditRouter.PostProcessor? = { reply, message in
            await altTextGenerator.postProcess(reply: reply, message: message)
        }

        return SiteAssistantSession(
            chat: chat,
            editObserver: { [weak chat] reply in
                Task { @MainActor in
                    chat?.recordEdit(reply)
                }
            },
            editPostProcessor: postProcessor
        )
    }
```

(Only the parameter list and the `dependencies.assistant(...)` call change — the doc comments above `SiteAssistantSession`/`editObserver` stay as they were.)

- [ ] **Step 4: Update the `SiteWindowModel` call site**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, find the `SiteAssistantSessionFactory.makeSession(...)` call (around line 1104):

```swift
        let assistantSession = SiteAssistantSessionFactory.makeSession(
            siteID: resolved.id,
            sourceDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            mcpClient: mcpClient,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            integrationService: integrationOps
        )
```

Replace it with:

```swift
        let assistantSession = SiteAssistantSessionFactory.makeSession(
            siteID: resolved.id,
            sourceDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            mcpClient: mcpClient,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            integrationService: integrationOps,
            graphSnapshotProvider: { [weak self] in
                guard let self else { return SiteGraphExplorerSnapshot(nodes: [], edges: []) }
                return await MainActor.run { self.graphExplorer.snapshot }
            }
        )
```

- [ ] **Step 5: Run the test to verify it passes, then the full app test target to check for regressions**

Run: `swift test --filter SiteAssistantSessionFactoryTests`
Expected: PASS

Run: `swift test --filter AnglesiteAppTests`
Expected: PASS (no regressions in the rest of the suite)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift
git commit -m "feat: wire SiteGraphAugmentedAssistant into the chat assistant chain (#314)"
```

---

### Task 4: `SiteWindowModel.revealCitationInGraph` — click-to-navigate

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (add method near `showGraph()`, line 213-217)
- Test: `Tests/AnglesiteAppTests/SiteWindowModelTests.swift` (append a new `extension SiteWindowModelTests`)

**Interfaces:**
- Consumes: `SiteGraphExplorerModel.snapshot` (existing, read-only), `SiteGraphExplorerModel.revealNode(_:)` (existing, `Sources/AnglesiteApp/SiteGraphExplorerModel.swift:68-72`), `SiteWindowModel.showGraph() async` (existing, line 213).
- Produces: `SiteWindowModel.revealCitationInGraph(_ path: String) -> Bool` — consumed by Task 5's `ChatView` wiring.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteAppTests/SiteWindowModelTests.swift`:

```swift
extension SiteWindowModelTests {
    @Test("revealCitationInGraph returns true and switches to the graph pane for a matching path")
    func revealCitationInGraphMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentGraph = SiteContentGraph()
        await contentGraph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date()
            )],
            posts: [], images: []
        )
        let model = makeModel(contentGraph: contentGraph)
        model.graphExplorer.start(siteID: "site-1", sourceDirectory: root)
        while model.graphExplorer.snapshot.nodes.isEmpty { await Task.yield() }

        let handled = model.revealCitationInGraph("src/pages/about.astro")

        #expect(handled)
        while model.mainPaneMode != .graph { await Task.yield() }
        #expect(model.graphExplorer.selectedNodeID == model.graphExplorer.snapshot.nodes.first?.id)
    }

    @Test("revealCitationInGraph returns false and does not switch panes for an unknown path")
    func revealCitationInGraphNoMatch() {
        let model = makeModel()

        let handled = model.revealCitationInGraph("src/pages/unknown.astro")

        #expect(!handled)
        #expect(model.mainPaneMode == .preview)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SiteWindowModelTests`
Expected: FAIL to compile — `revealCitationInGraph` doesn't exist yet.

- [ ] **Step 3: Implement `revealCitationInGraph`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add this method directly after `showGraph()` (line 217):

```swift
    /// Resolves a chat citation's file path to a Site Graph Explorer node and reveals it there
    /// (#314): switches the main pane to Graph and selects the node. Returns `false` — and does
    /// nothing — when the path doesn't match any node in the current snapshot, so the caller
    /// (`ChatView`'s citation click handler) can fall back to opening the file directly.
    ///
    /// The pane switch and selection happen asynchronously (matching `setPaneSelection`'s
    /// existing fire-and-forget `Task { await showGraph() }` pattern) — the `Bool` this returns
    /// reflects only whether a matching node was found, not whether the navigation has finished.
    @discardableResult
    func revealCitationInGraph(_ path: String) -> Bool {
        guard let node = graphExplorer.snapshot.nodes.first(where: { $0.filePath == path }) else {
            return false
        }
        Task { [weak self] in
            await self?.showGraph()
            self?.graphExplorer.revealNode(node)
        }
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SiteWindowModelTests`
Expected: PASS (all tests in the file, including the two new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/SiteWindowModelTests.swift
git commit -m "feat: reveal chat citations in the Site Graph Explorer (#314)"
```

---

### Task 5: Wire citation clicks in Chat to `revealCitationInGraph`

**Files:**
- Modify: `Sources/AnglesiteApp/CitationRowView.swift`
- Modify: `Sources/AnglesiteApp/ChatView.swift` (the `ChatView` struct header and `MessageRow`'s citation branch)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:187`

**Interfaces:**
- Consumes: `SiteWindowModel.revealCitationInGraph(_ path: String) -> Bool` (Task 4).

This task is pure SwiftUI view wiring — threading an optional closure through three views and calling it in a button action. There is no independently-testable logic here beyond what Task 4 already covers (the closure's *behavior* is tested there; this task only wires it to a UI element). Verification is a manual GUI check, matching how this codebase already tracks other GUI-only wiring (e.g. #491, #586) rather than a synthetic automated test for a one-line button action.

- [ ] **Step 1: Add the `revealCitation` parameter to `CitationRowView`**

In `Sources/AnglesiteApp/CitationRowView.swift`, replace the struct's properties and the `CitationChip` call site (lines 7-23) with:

```swift
struct CitationRowView: View {
    let citations: [RetrievedCitation]
    let siteDirectory: URL
    /// Resolves a citation's path to a Site Graph Explorer node and reveals it there; returns
    /// `false` when the path isn't a graph node, so the click falls back to opening the file
    /// (#314). `nil` in previews/tests that don't wire a graph explorer.
    var revealCitation: ((String) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(citations) { citation in
                    CitationChip(citation: citation) {
                        if revealCitation?(citation.path) == true { return }
                        let url = siteDirectory.appendingPathComponent(citation.path)
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
```

(The rest of the file — `.padding`/`.accessibilityElement` on the `VStack`, and all of `CitationChip`/`FlowLayout` below — is unchanged.)

- [ ] **Step 2: Thread `revealCitation` through `ChatView` and `MessageRow`**

In `Sources/AnglesiteApp/ChatView.swift`, add the property to `ChatView` right after `@Bindable var model: ChatModel` (line 17):

```swift
    @Bindable var model: ChatModel
    /// Resolves a citation's path to a Site Graph Explorer node and reveals it there; returns
    /// `false` when the path isn't a graph node, so the click falls back to opening the file
    /// (#314). `nil` in previews/tests that don't wire a graph explorer.
    var revealCitation: ((String) -> Bool)?
```

Update the `MessageRow` call site (line 97) from `MessageRow(message: message, model: model)` to:

```swift
                        MessageRow(message: message, model: model, revealCitation: revealCitation)
```

Update `MessageRow`'s properties and citation branch (lines 247-259) from:

```swift
private struct MessageRow: View {
    let message: ChatModel.Message
    let model: ChatModel

    var body: some View {
        if message.role == .edit {
            editRow
        } else if message.role == .annotation {
            AnnotationRowView(message: message, model: model)
        } else if message.role == .citation {
            if let meta = message.citationMetadata {
                CitationRowView(citations: meta.citations, siteDirectory: model.siteDirectoryURL)
            }
        } else {
```

to:

```swift
private struct MessageRow: View {
    let message: ChatModel.Message
    let model: ChatModel
    var revealCitation: ((String) -> Bool)?

    var body: some View {
        if message.role == .edit {
            editRow
        } else if message.role == .annotation {
            AnnotationRowView(message: message, model: model)
        } else if message.role == .citation {
            if let meta = message.citationMetadata {
                CitationRowView(citations: meta.citations, siteDirectory: model.siteDirectoryURL, revealCitation: revealCitation)
            }
        } else {
```

- [ ] **Step 3: Wire the closure at the `ChatView` call site**

In `Sources/AnglesiteApp/SiteWindow.swift`, replace line 187:

```swift
                            ChatView(model: chat)
```

with:

```swift
                            ChatView(model: chat, revealCitation: { path in model.revealCitationInGraph(path) })
```

(`model` here is the enclosing `SiteWindow`'s `SiteWindowModel`, already in scope — the same `model` used for `mainPane(for: site)` two lines above.)

- [ ] **Step 4: Build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Manual GUI verification**

Run the app (`open Anglesite.xcodeproj`, ⌘R), open a site with at least two pages where one imports a component (or open any existing test/sample site), open the Chat panel, and:

1. Ask a question naming a specific file/component/page by title (e.g. "How does the Header component work?" or the title of any real component in the open site).
2. Confirm a "Sources" chip row appears under the assistant's reply.
3. Click a chip. Confirm the main pane switches to the Graph view and the corresponding node is selected/highlighted.
4. Ask an unrelated question (e.g. "What's 2+2?"). Confirm no "Sources" row appears for that turn (or only the content-index one, if applicable) — the graph decorator should contribute nothing.
5. Click a citation chip whose kind maps from a knowledge-index result (not a graph node) — e.g. from an ordinary content-search citation. Confirm it still falls back to opening the file (regression check on the existing `NSWorkspace.shared.open` path).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/CitationRowView.swift Sources/AnglesiteApp/ChatView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat: reveal-in-graph on chat citation click (#314)"
```

---

### Task 6: Fix nested-decorator query pollution with `CombinedAugmentedAssistant`

**Why:** The final whole-branch review (after Tasks 1-5) found that nesting
`SiteGraphAugmentedAssistant(base: KnowledgeAugmentedAssistant(base: FoundationModelAssistant(...)))`
(Task 3's wiring) means `KnowledgeAugmentedAssistant.enrichedContext` searches
`SiteKnowledgeIndex` using the prompt `SiteGraphAugmentedAssistant` already rewrote — a blob of
instructions and fact lines, not the user's actual question — degrading the content-index
citations on exactly the structural questions this feature targets. Both decorators already
compute `(prompt, context) -> (enrichedText, citations)` independently; the fix is to run both
retrievals against the same, untouched prompt and merge once, instead of nesting.

**Files:**
- Modify: `Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift` (extract a reusable static retrieval step)
- Modify: `Sources/AnglesiteCore/KnowledgeAugmentedAssistant.swift` (extract a reusable static retrieval step)
- Create: `Sources/AnglesiteCore/CombinedAugmentedAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/CombinedAugmentedAssistantTests.swift`
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift:67-82` (only the body of the `assistant` closure changes — the `AssistantBuilder` typealias and `makeSession` signature from Task 3 are unchanged)

**Interfaces:**
- Consumes: `SiteGraphExplainPrompt.facts(...)` (Task 1, unchanged), `SiteGraphAugmentedAssistant`'s existing static helpers (Task 2), `KnowledgeAugmentedAssistant.formatContext` (existing).
- Produces: `SiteGraphAugmentedAssistant.graphBlock(prompt:snapshot:) -> (block: String, citations: [RetrievedCitation])?`, `KnowledgeAugmentedAssistant.contentBlock(prompt:context:index:) async -> (block: String, citations: [RetrievedCitation])?`, `public actor CombinedAugmentedAssistant: ConversationalAssistant` with `init(base:index:graphSnapshotProvider:)`.

The extractions in Steps 1-2 are pure refactors — each decorator's OWN `enrichedContext` must
keep producing byte-identical output to before, so `SiteGraphAugmentedAssistantTests` and
`KnowledgeAugmentedAssistantTests` must both keep passing unchanged.

- [ ] **Step 1: Extract `SiteGraphAugmentedAssistant.graphBlock(prompt:snapshot:)`**

Run baseline: `swift test --filter SiteGraphAugmentedAssistant` — Expected: PASS (5/5, established baseline)

In `Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift`, replace the `enrichedContext` method (current lines 82-109) with:

```swift
    private func enrichedContext(_ prompt: String) async -> (prompt: String, citations: [RetrievedCitation]) {
        let snapshot = await snapshotProvider()
        guard let (block, citations) = Self.graphBlock(prompt: prompt, snapshot: snapshot) else {
            return (prompt, [])
        }
        let enriched = """
        \(block)

        User request:
        \(prompt)
        """
        return (enriched, citations)
    }

    /// Builds the graph-facts block and citations for `prompt` against `snapshot`, or `nil` when
    /// no node matches. Exposed (not `private`) so ``CombinedAugmentedAssistant`` can run this
    /// retrieval directly against the original user question instead of a prompt another
    /// decorator already rewrote (#314).
    static func graphBlock(
        prompt: String,
        snapshot: SiteGraphExplorerSnapshot
    ) -> (block: String, citations: [RetrievedCitation])? {
        let seeds = seedNodes(for: prompt, in: snapshot)
        guard !seeds.isEmpty else { return nil }

        var blocks: [String] = []
        var citations: [RetrievedCitation] = []
        for node in seeds {
            guard let impact = ImpactAnalysis.analyze(snapshot: snapshot, targetID: node.id) else { continue }
            let (dependsOn, referencedBy) = neighbors(of: node, in: snapshot)
            let facts = SiteGraphExplainPrompt.facts(node: node, impact: impact, dependsOn: dependsOn, referencedBy: referencedBy)
            blocks.append("Facts about \(node.title):\n" + facts.joined(separator: "\n"))
            if let citation = citation(for: node) { citations.append(citation) }
        }
        guard !blocks.isEmpty else { return nil }

        let instructions = """
        You are answering a question about how this Astro website is built, using only the \
        facts below about specific files in its dependency graph. Do not invent details that \
        are not in the facts, and cite file paths when you use a fact.
        """
        return (instructions + "\n\n" + blocks.joined(separator: "\n\n"), citations)
    }
```

Run: `swift test --filter SiteGraphAugmentedAssistant`
Expected: PASS (same 5/5, output unchanged — this is a pure extraction)

- [ ] **Step 2: Extract `KnowledgeAugmentedAssistant.contentBlock(prompt:context:index:)`**

Run baseline: `swift test --filter KnowledgeAugmentedAssistant` — Expected: PASS (established baseline)

In `Sources/AnglesiteCore/KnowledgeAugmentedAssistant.swift`, replace the `enrichedContext` method (current lines 65-80) with:

```swift
    private func enrichedContext(_ prompt: String, context: AssistantContext) async -> (prompt: String, citations: [RetrievedCitation]) {
        guard let (block, citations) = await Self.contentBlock(prompt: prompt, context: context, index: index) else {
            return (prompt, [])
        }
        let enriched = """
        \(block)

        User request:
        \(prompt)
        """
        return (enriched, citations)
    }

    /// Builds the content-search block and citations for `prompt`, or `nil` when nothing
    /// matches. Exposed (not `private`) so ``CombinedAugmentedAssistant`` can run this retrieval
    /// directly against the original user question instead of a prompt another decorator already
    /// rewrote (#314).
    static func contentBlock(
        prompt: String,
        context: AssistantContext,
        index: SiteKnowledgeIndex
    ) async -> (block: String, citations: [RetrievedCitation])? {
        let results = await index.search(
            siteID: context.siteID,
            query: prompt,
            options: context.searchOptions
        )
        guard !results.isEmpty else { return nil }
        return (formatContext(results), results.map(RetrievedCitation.init))
    }
```

(`formatContext` is already `private static` — leave it as-is, unchanged.)

Run: `swift test --filter KnowledgeAugmentedAssistant`
Expected: PASS (same as baseline, output unchanged — this is a pure extraction)

- [ ] **Step 3: Write the failing tests for `CombinedAugmentedAssistant`**

Create `Tests/AnglesiteCoreTests/CombinedAugmentedAssistantTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4)
import FoundationModels
#endif

private actor CapturingConversationalAssistant: ConversationalAssistant {
    private(set) var prompts: [String] = []

    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Capture"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        prompts.append(prompt)
        return AsyncStream { continuation in
            continuation.yield(.started(model: "Capture", toolNames: []))
            continuation.yield(.textDelta("ok"))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        prompts.append(prompt)
        throw AssistantError.unsupported("capture assistant does not generate structured values")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}

@Suite("CombinedAugmentedAssistant")
struct CombinedAugmentedAssistantTests {
    private func node(
        _ id: String,
        kind: SiteGraphNodeKind = .component,
        title: String,
        filePath: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: kind, title: title, detail: nil, filePath: filePath, route: nil)
    }

    private func makeSite() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"),
            withIntermediateDirectories: true
        )
        return root
    }

    @Test("the content-index search runs against the original prompt, not a graph-enriched one")
    func contentSearchUsesOriginalPrompt() async throws {
        // A seed node whose title/facts would previously have polluted the content-index query
        // if it were nested inside SiteGraphAugmentedAssistant's enriched text.
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        for await _ in try await assistant.converse(prompt: "How does the Header work with the CTA?", context: context) {}

        // Both blocks must be present in the single prompt sent to `base` — proving the content
        // search ran (it found the CTA excerpt) using the ORIGINAL question, not text mutated by
        // the graph decorator first.
        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("User request:\nHow does the Header work with the CTA?") == true)
    }

    @Test("citations from both sources are merged into a single .citations event")
    func mergesCitationsIntoOneEvent() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "How does the Header work with the CTA?", context: context) {
            events.append(event)
        }

        let citationEvents = events.filter { if case .citations = $0 { return true } else { return false } }
        #expect(citationEvents.count == 1)
        guard case .citations(let citations) = citationEvents.first else {
            Issue.record("Expected exactly one .citations event")
            return
        }
        #expect(citations.contains { $0.path == "src/components/Header.astro" })
        #expect(citations.contains { $0.path == "src/components/CTA.astro" })
    }

    @Test("a path cited by both sources is only cited once, keeping the graph citation")
    func dedupesCitationsByPath() async throws {
        let cta = node("c1", title: "CTA", filePath: "src/components/CTA.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [cta], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "Tell me about the CTA component", context: context) {
            events.append(event)
        }

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected first event to be .citations")
            return
        }
        let ctaCitations = citations.filter { $0.path == "src/components/CTA.astro" }
        #expect(ctaCitations.count == 1)
        #expect(ctaCitations.first?.kind == .component)
    }

    @Test("neither source matching leaves the prompt untouched and skips citations")
    func neitherMatchesLeavesPromptUntouched() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(
            base: base, index: index,
            graphSnapshotProvider: { SiteGraphExplorerSnapshot(nodes: [], edges: []) }
        )
        let prompt = "Explain quantum entanglement"

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: prompt, context: AssistantContext(siteID: "site", siteDirectory: root)) {
            events.append(event)
        }

        #expect(await base.prompts.first == prompt)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter CombinedAugmentedAssistant`
Expected: FAIL with "cannot find 'CombinedAugmentedAssistant' in scope"

- [ ] **Step 5: Implement `CombinedAugmentedAssistant`**

Create `Sources/AnglesiteCore/CombinedAugmentedAssistant.swift`:

```swift
import Foundation

#if compiler(>=6.4)
import FoundationModels
#endif

/// Combines graph-structure grounding (``SiteGraphAugmentedAssistant``) and content-search
/// grounding (``KnowledgeAugmentedAssistant``) into a single enrichment pass, both run against
/// the same, untouched user prompt (#314).
///
/// Nesting the two decorators (each rewriting `prompt` and forwarding to the next) was the
/// original approach and was rejected: the inner decorator's retrieval search then runs against
/// the OUTER decorator's already-enriched prompt — a blob of instructions and fact lines, not
/// the user's actual question — degrading exactly the citations this feature is meant to
/// produce. Running both retrievals here, against the same original `prompt`, avoids that.
public actor CombinedAugmentedAssistant: ConversationalAssistant {
    private let base: any ConversationalAssistant
    private let index: SiteKnowledgeIndex
    private let graphSnapshotProvider: @Sendable () async -> SiteGraphExplorerSnapshot

    public init(
        base: any ConversationalAssistant,
        index: SiteKnowledgeIndex,
        graphSnapshotProvider: @escaping @Sendable () async -> SiteGraphExplorerSnapshot
    ) {
        self.base = base
        self.index = index
        self.graphSnapshotProvider = graphSnapshotProvider
    }

    public nonisolated var capabilities: AssistantCapabilities {
        base.capabilities
    }

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let (enriched, citations) = await enrichedContext(prompt, context: context)
        let baseStream = try await base.converse(prompt: enriched, context: context)
        guard !citations.isEmpty else { return baseStream }
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.citations(citations))
                for await event in baseStream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let (enriched, _) = await enrichedContext(prompt, context: context)
        return try await base.generate(prompt: enriched, context: context)
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let (enriched, _) = await enrichedContext(prompt, context: context)
        return try await base.generateStructured(prompt: enriched, context: context, resultType: resultType)
    }
    #endif

    public func cancel() async {
        await base.cancel()
    }

    public func resetSession() async {
        await base.resetSession()
    }

    private func enrichedContext(_ prompt: String, context: AssistantContext) async -> (prompt: String, citations: [RetrievedCitation]) {
        let snapshot = await graphSnapshotProvider()
        let graph = SiteGraphAugmentedAssistant.graphBlock(prompt: prompt, snapshot: snapshot)
        let content = await KnowledgeAugmentedAssistant.contentBlock(prompt: prompt, context: context, index: index)

        var blocks: [String] = []
        var citations: [RetrievedCitation] = []
        if let graph {
            blocks.append(graph.block)
            citations.append(contentsOf: graph.citations)
        }
        if let content {
            blocks.append(content.block)
            // A file that's both a matched graph node and a content-search hit is cited once —
            // the graph citation (added first, above) already covers it and carries the more
            // specific `SiteGraphNodeKind`-derived kind mapping.
            let citedPaths = Set(citations.map(\.path))
            citations.append(contentsOf: content.citations.filter { !citedPaths.contains($0.path) })
        }
        guard !blocks.isEmpty else { return (prompt, []) }

        let enriched = """
        \(blocks.joined(separator: "\n\n"))

        User request:
        \(prompt)
        """
        return (enriched, citations)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter CombinedAugmentedAssistant`
Expected: PASS (all 4 tests)

Also re-run the two extraction targets to confirm no regression:

Run: `swift test --filter SiteGraphAugmentedAssistant`
Expected: PASS (5/5)

Run: `swift test --filter KnowledgeAugmentedAssistant`
Expected: PASS (established baseline count)

- [ ] **Step 7: Wire `CombinedAugmentedAssistant` into `SiteAssistantSessionFactory`**

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, replace the `assistant` closure inside `Dependencies.live` (the one built in Task 3, currently constructing a nested `SiteGraphAugmentedAssistant(base: KnowledgeAugmentedAssistant(...))`) with:

```swift
            let assistant: AssistantBuilder = { editBridge, contentGraph, knowledgeIndex, semanticRanker, integrationService, graphSnapshotProvider in
                CombinedAugmentedAssistant(
                    base: FoundationModelAssistant(
                        tier: .onDevice,
                        editBridge: editBridge,
                        contentGraph: contentGraph,
                        knowledgeIndex: knowledgeIndex,
                        semanticRanker: semanticRanker,
                        integrationService: integrationService
                    ),
                    index: knowledgeIndex,
                    graphSnapshotProvider: graphSnapshotProvider
                )
            }
```

The `AssistantBuilder` typealias and `makeSession`'s signature (both from Task 3) are unchanged — only this closure's body changes. `SiteAssistantSessionFactoryTests` (Task 3) stubs `Dependencies.assistant` entirely and never constructs the production closure, so it needs no changes and must still pass unchanged.

- [ ] **Step 8: Run the full test suite and build to verify no regressions**

Run: `swift test`
Expected: PASS (every target, no regressions)

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/SiteGraphAugmentedAssistant.swift Sources/AnglesiteCore/KnowledgeAugmentedAssistant.swift Sources/AnglesiteCore/CombinedAugmentedAssistant.swift Tests/AnglesiteCoreTests/CombinedAugmentedAssistantTests.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift
git commit -m "fix: run graph and content RAG against the same original prompt (#314)

Nesting SiteGraphAugmentedAssistant around KnowledgeAugmentedAssistant meant the
inner content-index search ran against the outer decorator's already-enriched
prompt instead of the user's actual question, degrading citations on exactly the
structural questions #314 targets. CombinedAugmentedAssistant runs both
retrievals against the same original prompt and merges once."
```

---

## Self-Review Notes

- **Spec coverage:** Architecture (Task 2), Components (Tasks 1-2), Citations & navigation (Tasks 4-5), Error handling (no new task — verified by Task 2's existing-error-path tests inherited from the unchanged `FoundationModelAssistant`/`ChatModel` error surface), Testing (each task's own test file) — all spec sections have a task.
- **Type consistency checked:** `SiteGraphAugmentedAssistant.init(base:snapshotProvider:)` signature matches its Task 3 call site; `GraphSnapshotProvider`/`graphSnapshotProvider` naming is consistent across Tasks 2-3; `revealCitationInGraph(_:) -> Bool` signature matches its Task 5 closure usage `{ path in model.revealCitationInGraph(path) }`.
- **No placeholders:** every step has complete code; Task 5's "no automated test" is an explicit, justified scope decision (documented inline), not a placeholder.
