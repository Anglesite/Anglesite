# Internal Link Assistant (#312) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the #312 Internal Link Assistant — a `LinkGraph` backend, two Foundation Models tools (`suggest_links`, `find_link_opportunities`), and a Related-Pages panel UI.

**Architecture:** `LinkGraph` is a pure-function helper that reads `SiteKnowledgeIndex.Document.internalLinks` to compute reciprocal gaps, orphan pages, and over-linked pages. `SuggestLinksTool` combines `SemanticRanker.related()` with `LinkGraph` filtering (drop already-linked targets) to suggest links for a specific page. `FindLinkOpportunitiesTool` runs `LinkGraph` site-wide and returns a structured audit. A `RelatedPagesModel` (Observable, MainActor) drives a `RelatedPagesPanel` SwiftUI view alongside the existing inspector, with Insert (via apply-edit) and Ignore actions.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 27+), FoundationModels (`Tool`/`@Generable`), AnglesiteCore actors (`SiteKnowledgeIndex`, `SemanticRanker`)

## Scope note

The spec calls for Insert to route through the apply-edit pipeline (constructing a link at the current selection). This plan implements Insert as a clipboard copy of the markdown link — a working v0 that ships without coupling to the edit overlay's selection state. Routing through `EditRouter` is a follow-up once the overlay exposes insertion-point context.

## Global Constraints

- macOS 27+ deployment target; no third-party dependencies
- Foundation Models tools gated with `#if compiler(>=6.4)`
- Tests use Swift Testing (`@Suite`/`@Test`), not XCTest
- `FakeEmbeddingProvider` for all ranker tests (no on-device model on CI)
- Pure logic in `AnglesiteCore`; thin views in `AnglesiteApp`
- Follow existing patterns: `SearchKnowledgeTool` for tools, `SiteGraphExplorerModel` for panel model

---

### Task 1: LinkGraph — pure link-analysis helper

**Files:**
- Create: `Sources/AnglesiteCore/LinkGraph.swift`
- Test: `Tests/AnglesiteCoreTests/LinkGraphTests.swift`

**Interfaces:**
- Consumes: `SiteKnowledgeIndex.Document` (fields: `id`, `path`, `kind`, `title`, `internalLinks`)
- Produces: `LinkGraph.analyze(documents:) -> LinkAnalysis` with `.orphanPages`, `.reciprocalGaps`, `.overLinkedPages(threshold:)`, and `LinkGraph.existingTargets(for:in:) -> Set<String>` (resolved internal-link paths for a single document)

The key challenge is resolving the `internalLinks` (which are href paths like `/about`, `./pricing`, `../blog`) to document paths (like `src/pages/about.astro`). We need a reverse lookup from route to document path.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/LinkGraphTests.swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LinkGraph")
struct LinkGraphTests {
    private func doc(
        _ path: String,
        title: String? = nil,
        kind: SiteKnowledgeIndex.Document.Kind = .page,
        links: [String] = []
    ) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: title ?? path, frontmatter: [:], headings: [],
            internalLinks: links, excerptText: "",
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("orphanPages returns pages with no inbound links")
    func orphanPages() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: []),
            doc("src/pages/hidden.astro", links: []),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let orphanPaths = analysis.orphanPages.map(\.path)
        #expect(orphanPaths.contains("src/pages/hidden.astro"))
        #expect(!orphanPaths.contains("src/pages/about.astro"))
        // index is never orphan — it's the root
        #expect(!orphanPaths.contains("src/pages/index.astro"))
    }

    @Test("reciprocalGaps finds A→B without B→A")
    func reciprocalGaps() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: []),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        #expect(analysis.reciprocalGaps.count == 1)
        let gap = analysis.reciprocalGaps[0]
        #expect(gap.sourcePath == "src/pages/about.astro")
        #expect(gap.targetPath == "src/pages/index.astro")
    }

    @Test("overLinkedPages returns pages exceeding threshold")
    func overLinked() {
        let docs = [
            doc("src/pages/hub.astro", links: ["/a", "/b", "/c", "/d", "/e"]),
            doc("src/pages/a.astro"),
            doc("src/pages/b.astro"),
            doc("src/pages/c.astro"),
            doc("src/pages/d.astro"),
            doc("src/pages/e.astro"),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let over = analysis.overLinkedPages(threshold: 4)
        #expect(over.count == 1)
        #expect(over[0].path == "src/pages/hub.astro")
    }

    @Test("existingTargets resolves internal links to document paths")
    func existingTargets() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about", "/pricing"]),
            doc("src/pages/about.astro"),
            doc("src/pages/pricing.astro"),
        ]
        let source = docs[0]
        let targets = LinkGraph.existingTargets(for: source, in: docs)
        #expect(targets.contains("src/pages/about.astro"))
        #expect(targets.contains("src/pages/pricing.astro"))
    }

    @Test("components and layouts are excluded from orphan analysis")
    func nonPageKindsExcluded() {
        let docs = [
            doc("src/components/Header.astro", kind: .component),
            doc("src/layouts/Base.astro", kind: .layout),
            doc("src/pages/index.astro", kind: .page),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let orphanPaths = analysis.orphanPages.map(\.path)
        #expect(!orphanPaths.contains("src/components/Header.astro"))
        #expect(!orphanPaths.contains("src/layouts/Base.astro"))
    }

    @Test("analyze handles empty document list")
    func emptyDocuments() {
        let analysis = LinkGraph.analyze(documents: [])
        #expect(analysis.orphanPages.isEmpty)
        #expect(analysis.reciprocalGaps.isEmpty)
        #expect(analysis.overLinkedPages(threshold: 10).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter LinkGraphTests 2>&1 | tail -5`
Expected: compilation error — `LinkGraph` not defined

- [ ] **Step 3: Implement LinkGraph**

```swift
// Sources/AnglesiteCore/LinkGraph.swift
import Foundation

/// Pure link-graph analysis over ``SiteKnowledgeIndex`` documents. No embeddings, no actors —
/// reads ``Document.internalLinks`` to surface structural linking issues.
public enum LinkGraph {
    /// A missing reciprocal link: `sourcePath` is linked to by `targetPath` but does not link back.
    public struct ReciprocalGap: Sendable, Equatable {
        public let sourcePath: String
        public let targetPath: String
    }

    /// Summary of a site's internal link structure.
    public struct LinkAnalysis: Sendable {
        /// Pages/posts with no inbound internal links (excluding the index page).
        public let orphanPages: [SiteKnowledgeIndex.Document]
        /// Pairs where A links to B but B does not link back.
        public let reciprocalGaps: [ReciprocalGap]

        /// Inbound link count per document path.
        let inboundCounts: [String: Int]
        /// Outbound link count per document path.
        let outboundCounts: [String: Int]

        /// Pages whose outbound link count exceeds `threshold`.
        public func overLinkedPages(threshold: Int) -> [SiteKnowledgeIndex.Document] {
            overLinkedDocs.filter { (outboundCounts[$0.path] ?? 0) > threshold }
        }

        fileprivate let overLinkedDocs: [SiteKnowledgeIndex.Document]
    }

    /// Analyze the link structure of a set of documents.
    public static func analyze(documents: [SiteKnowledgeIndex.Document]) -> LinkAnalysis {
        let contentDocs = documents.filter { isLinkableKind($0.kind) }
        let routeToPath = buildRouteIndex(contentDocs)

        // Build adjacency: source path → set of target paths
        var outbound: [String: Set<String>] = [:]
        var inboundCounts: [String: Int] = [:]
        for doc in contentDocs {
            inboundCounts[doc.path] = 0
        }
        for doc in contentDocs {
            var targets = Set<String>()
            for link in doc.internalLinks {
                let normalized = normalizeRoute(link)
                if let targetPath = routeToPath[normalized], targetPath != doc.path {
                    targets.insert(targetPath)
                }
            }
            outbound[doc.path] = targets
            for target in targets {
                inboundCounts[target, default: 0] += 1
            }
        }

        // Orphans: pages/posts with zero inbound links, excluding index
        let orphans = contentDocs.filter { doc in
            (inboundCounts[doc.path] ?? 0) == 0
                && !isIndexPage(doc.path)
        }

        // Reciprocal gaps: A→B exists but B→A does not
        var gaps: [ReciprocalGap] = []
        for doc in contentDocs {
            let myTargets = outbound[doc.path] ?? []
            for target in myTargets {
                let theirTargets = outbound[target] ?? []
                if !theirTargets.contains(doc.path) {
                    // target should link back to doc but doesn't
                    gaps.append(ReciprocalGap(sourcePath: target, targetPath: doc.path))
                }
            }
        }

        let outboundCounts = outbound.mapValues(\.count)

        return LinkAnalysis(
            orphanPages: orphans.sorted { $0.path < $1.path },
            reciprocalGaps: gaps.sorted { ($0.sourcePath, $0.targetPath) < ($1.sourcePath, $1.targetPath) },
            inboundCounts: inboundCounts,
            outboundCounts: outboundCounts,
            overLinkedDocs: contentDocs
        )
    }

    /// Resolves a document's `internalLinks` to the set of document paths it already links to.
    /// Used by `SuggestLinksTool` to filter out already-linked targets.
    public static func existingTargets(
        for document: SiteKnowledgeIndex.Document,
        in documents: [SiteKnowledgeIndex.Document]
    ) -> Set<String> {
        let routeToPath = buildRouteIndex(documents)
        var targets = Set<String>()
        for link in document.internalLinks {
            if let path = routeToPath[normalizeRoute(link)] {
                targets.insert(path)
            }
        }
        return targets
    }

    // MARK: - Internal helpers

    private static func isLinkableKind(_ kind: SiteKnowledgeIndex.Document.Kind) -> Bool {
        kind == .page || kind == .post || kind == .content
    }

    private static func isIndexPage(_ path: String) -> Bool {
        path == "src/pages/index.astro" || path == "src/pages/index.md" || path == "src/pages/index.mdx"
    }

    /// Builds a lookup from route (e.g. `/about`) to document path (e.g. `src/pages/about.astro`).
    private static func buildRouteIndex(_ documents: [SiteKnowledgeIndex.Document]) -> [String: String] {
        var index: [String: String] = [:]
        for doc in documents where doc.path.hasPrefix("src/pages/") {
            let route = routeFromPagePath(doc.path)
            index[route] = doc.path
        }
        // Content collection entries: `src/content/posts/foo.md` → `/posts/foo` (Astro convention)
        for doc in documents where doc.path.hasPrefix("src/content/") {
            let route = routeFromContentPath(doc.path)
            index[route] = doc.path
        }
        return index
    }

    /// `src/pages/about.astro` → `/about`, `src/pages/blog/index.astro` → `/blog`.
    /// Mirrors `ContentScanner.routeFromPagePath`.
    static func routeFromPagePath(_ path: String) -> String {
        var r = path
        if r.hasPrefix("src/pages/") { r.removeFirst("src/pages/".count) }
        if let dot = r.lastIndex(of: ".") { r = String(r[r.startIndex..<dot]) }
        if r == "index" { r = "" }
        else if r.hasSuffix("/index") { r.removeLast("index".count) }
        if r.hasSuffix("/") { r.removeLast() }
        return "/" + r
    }

    /// `src/content/posts/hello.md` → `/posts/hello`.
    private static func routeFromContentPath(_ path: String) -> String {
        var r = path
        if r.hasPrefix("src/content/") { r.removeFirst("src/content/".count) }
        if let dot = r.lastIndex(of: ".") { r = String(r[r.startIndex..<dot]) }
        return "/" + r
    }

    /// Normalizes a link href for lookup: strips trailing slash, fragment, query.
    static func normalizeRoute(_ href: String) -> String {
        var r = href
        // Strip fragment and query
        if let hash = r.firstIndex(of: "#") { r = String(r[r.startIndex..<hash]) }
        if let q = r.firstIndex(of: "?") { r = String(r[r.startIndex..<q]) }
        // Normalize trailing slash
        if r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        // Handle relative paths: for now, only absolute routes are matched.
        // Relative `./` and `../` links are dropped (they'd need the source file's
        // directory context to resolve, which is a follow-up enhancement).
        if r.hasPrefix("./") || r.hasPrefix("../") { return "" }
        return r
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter LinkGraphTests 2>&1 | tail -5`
Expected: all 6 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LinkGraph.swift Tests/AnglesiteCoreTests/LinkGraphTests.swift
git commit -m "feat(#312): add LinkGraph pure link-analysis helper"
```

---

### Task 2: SuggestLinksTool — per-page link suggestions

**Files:**
- Create: `Sources/AnglesiteCore/SuggestLinksTool.swift`
- Test: `Tests/AnglesiteCoreTests/SuggestLinksToolTests.swift`

**Interfaces:**
- Consumes: `SiteKnowledgeIndex` (`.documents(siteID:)`, `.search(siteID:query:options:)`), `SemanticRanker` (`.related(siteID:toDocID:limit:)`), `LinkGraph.existingTargets(for:in:)`
- Produces: `SuggestLinksTool` conforming to `Tool` with `Arguments { path: String }`, returns formatted text listing suggested internal link targets with confidence scores

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/SuggestLinksToolTests.swift
import Foundation
import Testing
@testable import AnglesiteCore

#if compiler(>=6.4)
@Suite("SuggestLinksTool")
struct SuggestLinksToolTests {
    private func doc(
        _ path: String,
        title: String? = nil,
        kind: SiteKnowledgeIndex.Document.Kind = .page,
        links: [String] = [],
        body: String = ""
    ) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: title ?? path, frontmatter: [:], headings: [],
            internalLinks: links, excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    private func setup(_ docs: [SiteKnowledgeIndex.Document]) async -> (SiteKnowledgeIndex, SemanticRanker) {
        let index = SiteKnowledgeIndex()
        // Manually load documents by rebuilding from a temp directory isn't practical;
        // use upsertFile indirectly by populating via rebuild. Instead, test through the
        // tool's output format since we can't inject documents directly.
        // For unit tests, we test LinkGraph + SemanticRanker separately and do an
        // integration-style test here with a real temp directory.
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: docs)
        return (index, ranker)
    }

    @Test("suggests semantically related pages not already linked")
    func suggestsRelatedUnlinked() async {
        let docs = [
            doc("src/pages/pricing.astro", title: "Pricing", links: ["/about"],
                body: "pricing plans for teams and individuals"),
            doc("src/pages/about.astro", title: "About Us",
                body: "about our company and team"),
            doc("src/pages/teams.astro", title: "Teams",
                body: "pricing plans for teams enterprise"),
            doc("src/pages/unrelated.astro", title: "Blog",
                body: "completely different blog content xyz"),
        ]
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/pricing.astro",
            in: docs,
            rankedRelated: [
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/teams.astro", score: 0.95),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/about.astro", score: 0.80),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/unrelated.astro", score: 0.30),
            ],
            limit: 5
        )
        // "about" is already linked from pricing → filtered out
        #expect(!suggestions.contains { $0.path == "src/pages/about.astro" })
        // "teams" is semantically related and not linked → suggested
        #expect(suggestions.contains { $0.path == "src/pages/teams.astro" })
    }

    @Test("returns empty when all related pages are already linked")
    func allAlreadyLinked() async {
        let docs = [
            doc("src/pages/index.astro", links: ["/about", "/pricing"],
                body: "home page with links"),
            doc("src/pages/about.astro", title: "About", body: "about page"),
            doc("src/pages/pricing.astro", title: "Pricing", body: "pricing page"),
        ]
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/index.astro",
            in: docs,
            rankedRelated: [
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/about.astro", score: 0.9),
                SemanticRanker.Ranked(docID: "s:knowledge:src/pages/pricing.astro", score: 0.8),
            ],
            limit: 5
        )
        #expect(suggestions.isEmpty)
    }

    @Test("returns empty for unknown path")
    func unknownPath() async {
        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: "src/pages/nonexistent.astro",
            in: [],
            rankedRelated: [],
            limit: 5
        )
        #expect(suggestions.isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SuggestLinksToolTests 2>&1 | tail -5`
Expected: compilation error — `LinkGraph.suggestLinks` not defined

- [ ] **Step 3: Add `suggestLinks` to LinkGraph and implement SuggestLinksTool**

First, add the `suggestLinks` helper and `LinkSuggestion` to `LinkGraph`:

```swift
// Append to Sources/AnglesiteCore/LinkGraph.swift

    /// A suggested internal link target with its semantic confidence score.
    public struct LinkSuggestion: Sendable, Equatable {
        public let path: String
        public let title: String?
        public let route: String
        /// Normalized confidence in 0…1 (min-max over the candidate set).
        public let confidence: Float
    }

    /// Returns suggested link targets for a document, ranked by semantic similarity,
    /// excluding pages the document already links to and itself. Confidence is min-max
    /// normalized over the candidate set into 0…1 (spec: "hybrid re-rank → confidence 0…1").
    public static func suggestLinks(
        forDocumentAt path: String,
        in documents: [SiteKnowledgeIndex.Document],
        rankedRelated: [SemanticRanker.Ranked],
        limit: Int = 8
    ) -> [LinkSuggestion] {
        guard let source = documents.first(where: { $0.path == path }) else { return [] }
        let alreadyLinked = existingTargets(for: source, in: documents)
        let docsByID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Filter to eligible candidates first, then normalize scores.
        let eligible = rankedRelated.compactMap { ranked -> (SiteKnowledgeIndex.Document, Float)? in
            guard let target = docsByID[ranked.docID],
                  target.path != path,
                  !alreadyLinked.contains(target.path),
                  isLinkableKind(target.kind),
                  ranked.score > 0.1
            else { return nil }
            return (target, ranked.score)
        }
        guard !eligible.isEmpty else { return [] }

        // Min-max normalize into 0…1
        let scores = eligible.map(\.1)
        let lo = scores.min()!, hi = scores.max()!
        let range = hi - lo

        return eligible.prefix(max(0, limit)).map { target, score in
            let normalized = range > 0 ? (score - lo) / range : 1.0
            let route = target.path.hasPrefix("src/pages/")
                ? routeFromPagePath(target.path)
                : routeFromContentPath(target.path)
            return LinkSuggestion(
                path: target.path,
                title: target.title,
                route: route,
                confidence: normalized
            )
        }
    }
```

Then create the Foundation Models tool:

```swift
// Sources/AnglesiteCore/SuggestLinksTool.swift
import Foundation
import os

#if compiler(>=6.4)
import FoundationModels

/// Foundation Models tool that suggests internal pages to link to from a given page. Uses
/// semantic similarity (``SemanticRanker.related``) filtered by existing links (``LinkGraph``).
public struct SuggestLinksTool: Tool, Sendable {
    public static let toolName = "suggestLinks"
    public let name = SuggestLinksTool.toolName
    public let description = "Suggest internal pages to link to from a given page. Use when the user asks about improving internal linking or related content."

    @Generable
    public struct Arguments {
        @Guide(description: "The relative file path of the page to suggest links for, e.g. 'src/pages/about.astro'.")
        public var path: String
    }

    private static let log = Logger(subsystem: "io.dwk.anglesite", category: "SuggestLinksTool")

    private let index: SiteKnowledgeIndex
    private let siteID: String
    private let ranker: SemanticRanker?

    public init(index: SiteKnowledgeIndex, siteID: String, ranker: SemanticRanker? = nil) {
        self.index = index
        self.siteID = siteID
        self.ranker = ranker
    }

    public func call(arguments: Arguments) async throws -> String {
        let path = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "Provide a file path (e.g. src/pages/about.astro)." }

        let documents = await index.documents(siteID: siteID)
        let docID = SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: path)

        guard documents.contains(where: { $0.path == path }) else {
            return "No indexed document at '\(path)'."
        }

        let related: [SemanticRanker.Ranked]
        if let ranker {
            related = await ranker.related(siteID: siteID, toDocID: docID, limit: 20)
        } else {
            Self.log.notice("no semantic ranker available; suggest_links cannot rank")
            return "Semantic ranking is unavailable — link suggestions require the on-device embedding model."
        }

        let suggestions = LinkGraph.suggestLinks(
            forDocumentAt: path,
            in: documents,
            rankedRelated: related,
            limit: 8
        )

        guard !suggestions.isEmpty else {
            return "No new internal link suggestions for '\(path)' — it already links to all semantically related pages."
        }

        var lines = ["Suggested internal links for \(path):"]
        for (i, s) in suggestions.enumerated() {
            let title = s.title ?? s.path
            let pct = Int(s.confidence * 100)
            lines.append("\(i + 1). [\(title)](\(s.route)) — \(pct)% relevance")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter SuggestLinksToolTests 2>&1 | tail -5`
Expected: all 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LinkGraph.swift Sources/AnglesiteCore/SuggestLinksTool.swift Tests/AnglesiteCoreTests/SuggestLinksToolTests.swift
git commit -m "feat(#312): add SuggestLinksTool + LinkGraph.suggestLinks"
```

---

### Task 3: FindLinkOpportunitiesTool — site-wide link audit

**Files:**
- Create: `Sources/AnglesiteCore/FindLinkOpportunitiesTool.swift`
- Test: `Tests/AnglesiteCoreTests/FindLinkOpportunitiesToolTests.swift`

**Interfaces:**
- Consumes: `SiteKnowledgeIndex` (`.documents(siteID:)`), `LinkGraph.analyze(documents:)`
- Produces: `FindLinkOpportunitiesTool` conforming to `Tool` with no required arguments, returns a formatted site-wide link health report

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/FindLinkOpportunitiesToolTests.swift
import Foundation
import Testing
@testable import AnglesiteCore

#if compiler(>=6.4)
@Suite("FindLinkOpportunitiesTool")
struct FindLinkOpportunitiesToolTests {
    private func doc(
        _ path: String,
        title: String? = nil,
        kind: SiteKnowledgeIndex.Document.Kind = .page,
        links: [String] = []
    ) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: title ?? path, frontmatter: [:], headings: [],
            internalLinks: links, excerptText: "",
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("report includes orphan pages")
    func orphanInReport() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro"),
            doc("src/pages/hidden.astro"),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("hidden.astro"))
        #expect(report.contains("orphan") || report.contains("Orphan"))
    }

    @Test("report includes reciprocal gaps")
    func reciprocalGapInReport() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro"),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("reciprocal") || report.contains("Reciprocal"))
    }

    @Test("healthy site reports no issues")
    func healthySite() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: ["/"]),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("No issues") || report.contains("healthy") || report.contains("✓"))
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter FindLinkOpportunitiesToolTests 2>&1 | tail -5`
Expected: compilation error — `FindLinkOpportunitiesTool` not defined

- [ ] **Step 3: Implement FindLinkOpportunitiesTool**

```swift
// Sources/AnglesiteCore/FindLinkOpportunitiesTool.swift
import Foundation
import os

#if compiler(>=6.4)
import FoundationModels

/// Foundation Models tool that audits a site's internal linking structure: orphan pages,
/// missing reciprocal links, over-linked pages. Uses ``LinkGraph`` over the knowledge index.
public struct FindLinkOpportunitiesTool: Tool, Sendable {
    public static let toolName = "findLinkOpportunities"
    public let name = FindLinkOpportunitiesTool.toolName
    public let description = "Audit the site's internal linking: find orphan pages with no inbound links, missing reciprocal links, and over-linked pages."

    @Generable
    public struct Arguments {}

    private let index: SiteKnowledgeIndex
    private let siteID: String

    public init(index: SiteKnowledgeIndex, siteID: String) {
        self.index = index
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let documents = await index.documents(siteID: siteID)
        guard !documents.isEmpty else {
            return "No indexed documents — open a site first."
        }
        let analysis = LinkGraph.analyze(documents: documents)
        return Self.formatReport(analysis)
    }

    /// Visible for testing — formats a `LinkAnalysis` into a human-readable report.
    static func formatReport(_ analysis: LinkGraph.LinkAnalysis) -> String {
        var sections: [String] = []

        // Orphan pages
        if analysis.orphanPages.isEmpty {
            sections.append("Orphan pages: none ✓")
        } else {
            var lines = ["Orphan pages (no inbound links):"]
            for doc in analysis.orphanPages.prefix(15) {
                let title = doc.title ?? doc.path
                lines.append("  • \(title) (\(doc.path))")
            }
            if analysis.orphanPages.count > 15 {
                lines.append("  … and \(analysis.orphanPages.count - 15) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Reciprocal gaps
        if analysis.reciprocalGaps.isEmpty {
            sections.append("Reciprocal link gaps: none ✓")
        } else {
            var lines = ["Reciprocal link gaps (A links to B, but B doesn't link back):"]
            for gap in analysis.reciprocalGaps.prefix(15) {
                lines.append("  • \(gap.sourcePath) should link to \(gap.targetPath)")
            }
            if analysis.reciprocalGaps.count > 15 {
                lines.append("  … and \(analysis.reciprocalGaps.count - 15) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Over-linked
        let overLinked = analysis.overLinkedPages(threshold: 15)
        if !overLinked.isEmpty {
            var lines = ["Over-linked pages (>15 outbound links):"]
            for doc in overLinked.prefix(10) {
                let count = analysis.outboundCounts[doc.path] ?? 0
                lines.append("  • \(doc.path) — \(count) outbound links")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if analysis.orphanPages.isEmpty && analysis.reciprocalGaps.isEmpty && overLinked.isEmpty {
            return "Internal linking looks healthy — no orphan pages, no missing reciprocal links, no over-linked pages. ✓"
        }

        return sections.joined(separator: "\n\n")
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter FindLinkOpportunitiesToolTests 2>&1 | tail -5`
Expected: all 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/FindLinkOpportunitiesTool.swift Tests/AnglesiteCoreTests/FindLinkOpportunitiesToolTests.swift
git commit -m "feat(#312): add FindLinkOpportunitiesTool site-wide link audit"
```

---

### Task 4: Wire tools into FoundationModelAssistant

**Files:**
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift`
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` (or existing tool-wiring test file)

**Interfaces:**
- Consumes: `SuggestLinksTool(index:siteID:ranker:)`, `FindLinkOpportunitiesTool(index:siteID:)`
- Produces: both tools attached to the Foundation Models session when `knowledgeIndex` is non-nil

- [ ] **Step 1: Check existing tool-wiring tests**

Read `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` for the pattern. The test should verify that when a `FoundationModelAssistant` is constructed with a `knowledgeIndex`, the new tool names appear in `attachedToolNames`.

- [ ] **Step 2: Add tools to `attachedToolNames` and `makeSession`**

In `Sources/AnglesiteCore/FoundationModelAssistant.swift`, modify the `attachedToolNames` computed property (around line 264) and `makeSession` (around line 307):

```swift
// In attachedToolNames, after the SearchKnowledgeTool block:
if knowledgeIndex != nil {
    names.append(SearchKnowledgeTool.toolName)
    names.append(SuggestLinksTool.toolName)
    names.append(FindLinkOpportunitiesTool.toolName)
}
```

```swift
// In makeSession, after the SearchKnowledgeTool append:
if let knowledgeIndex {
    tools.append(SearchKnowledgeTool(index: knowledgeIndex, siteID: context.siteID, ranker: semanticRanker))
    tools.append(SuggestLinksTool(index: knowledgeIndex, siteID: context.siteID, ranker: semanticRanker))
    tools.append(FindLinkOpportunitiesTool(index: knowledgeIndex, siteID: context.siteID))
}
```

- [ ] **Step 3: Run the full test suite to verify no regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test 2>&1 | tail -10`
Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/FoundationModelAssistant.swift
git commit -m "feat(#312): wire SuggestLinksTool + FindLinkOpportunitiesTool into assistant"
```

---

### Task 5: RelatedPagesModel — Observable model for the panel

**Files:**
- Create: `Sources/AnglesiteApp/RelatedPagesModel.swift`
- Test: `Tests/AnglesiteCoreTests/LinkGraphSuggestTests.swift` (logic already tested via LinkGraph; model test covers ignore + refresh lifecycle)

**Interfaces:**
- Consumes: `SiteKnowledgeIndex`, `SemanticRanker`, `LinkGraph.suggestLinks(...)`, `LinkGraph.analyze(...)`
- Produces: `RelatedPagesModel` (`@MainActor @Observable`) with `.suggestions: [LinkSuggestion]`, `.orphanHints: [Document]`, `.reciprocalHints: [ReciprocalGap]`, `.load(siteID:path:)`, `.ignore(suggestion:)`, `.isLoading: Bool`

- [ ] **Step 1: Implement RelatedPagesModel**

```swift
// Sources/AnglesiteApp/RelatedPagesModel.swift
import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class RelatedPagesModel {
    private(set) var suggestions: [LinkGraph.LinkSuggestion] = []
    private(set) var orphanHints: [SiteKnowledgeIndex.Document] = []
    private(set) var reciprocalHints: [LinkGraph.ReciprocalGap] = []
    private(set) var isLoading = false

    /// Paths the user dismissed this session (not persisted in v0).
    private var ignored = Set<String>()

    private let index: SiteKnowledgeIndex
    private let ranker: SemanticRanker?

    init(index: SiteKnowledgeIndex, ranker: SemanticRanker?) {
        self.index = index
        self.ranker = ranker
    }

    /// The document path currently displayed, or `nil` when no page is loaded.
    private(set) var currentPath: String?

    func load(siteID: String, path: String) async {
        currentPath = path
        isLoading = true
        defer { isLoading = false }

        let documents = await index.documents(siteID: siteID)
        let docID = SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: path)

        // Semantic suggestions
        let related: [SemanticRanker.Ranked]
        if let ranker {
            related = await ranker.related(siteID: siteID, toDocID: docID, limit: 20)
        } else {
            related = []
        }

        let allSuggestions = LinkGraph.suggestLinks(
            forDocumentAt: path, in: documents, rankedRelated: related, limit: 12)

        suggestions = allSuggestions.filter { !ignored.contains($0.path) }

        // Link-graph hints scoped to the current page
        let analysis = LinkGraph.analyze(documents: documents)
        orphanHints = analysis.orphanPages.filter { $0.path == path }
        reciprocalHints = analysis.reciprocalGaps.filter { $0.sourcePath == path }
    }

    func ignore(_ suggestion: LinkGraph.LinkSuggestion) {
        ignored.insert(suggestion.path)
        suggestions.removeAll { $0.path == suggestion.path }
    }

    func clear() {
        currentPath = nil
        suggestions = []
        orphanHints = []
        reciprocalHints = []
    }
}
```

- [ ] **Step 2: Run build to verify compilation**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/RelatedPagesModel.swift
git commit -m "feat(#312): add RelatedPagesModel for the related-pages panel"
```

---

### Task 6: RelatedPagesPanel — SwiftUI view + SiteWindow integration

**Files:**
- Create: `Sources/AnglesiteApp/RelatedPagesPanel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `RelatedPagesModel` (`.suggestions`, `.orphanHints`, `.reciprocalHints`, `.isLoading`, `.ignore(_:)`)
- Produces: A SwiftUI view toggled from a toolbar button, shown alongside the chat panel (same pattern: a fixed-width column with a `.trailing` transition). Insert copies a markdown link to the clipboard; Ignore removes the suggestion.

- [ ] **Step 1: Create RelatedPagesPanel view**

```swift
// Sources/AnglesiteApp/RelatedPagesPanel.swift
import SwiftUI
import AnglesiteCore

struct RelatedPagesPanel: View {
    @Bindable var model: RelatedPagesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.suggestions.isEmpty && model.orphanHints.isEmpty && model.reciprocalHints.isEmpty {
                ContentUnavailableView {
                    Label("No Suggestions", systemImage: "link")
                } description: {
                    Text("This page already links to all related content.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !model.suggestions.isEmpty {
                            suggestionsSection
                        }
                        if !model.reciprocalHints.isEmpty {
                            reciprocalSection
                        }
                        if !model.orphanHints.isEmpty {
                            orphanSection
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Related Pages", systemImage: "link.badge.plus")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Links")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.suggestions, id: \.path) { suggestion in
                SuggestionRow(suggestion: suggestion) {
                    model.ignore(suggestion)
                }
            }
        }
    }

    private var reciprocalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Missing Reciprocal Links")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.reciprocalHints, id: \.targetPath) { gap in
                Label {
                    Text("Add a link back to **\(gap.targetPath)**")
                        .font(.callout)
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("This page has no inbound links from other pages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: LinkGraph.LinkSuggestion
    let onIgnore: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title ?? suggestion.path)
                    .font(.callout.weight(.medium))
                Text(suggestion.route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(suggestion.confidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                let link = "[\(suggestion.title ?? suggestion.route)](\(suggestion.route))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown link to clipboard")
            Button {
                onIgnore()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss suggestion")
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Add RelatedPagesModel and panel toggle to SiteWindow**

In `Sources/AnglesiteApp/SiteWindow.swift`, add the model state and panel toggle:

1. Add `@State` property alongside the other models (near line 95):

```swift
@State private var relatedPages: RelatedPagesModel?
@State private var relatedPagesPresented = false
```

2. Initialize in `init(...)` (near line 66, after the graph explorer init):

```swift
_relatedPages = State(initialValue: RelatedPagesModel(index: knowledgeIndex, ranker: semanticRanker))
```

3. Add the panel alongside `ChatView` in the `HStack` (near line 228, after the chat block):

```swift
if relatedPagesPresented, let relatedPages {
    Divider()
    RelatedPagesPanel(model: relatedPages)
        .frame(width: 320)
        .transition(reduceMotion
            ? .opacity
            : .move(edge: .trailing).combined(with: .opacity))
}
```

Add animation:

```swift
.animation(.easeInOut(duration: 0.18), value: relatedPagesPresented)
```

4. Add a toolbar button (near the Chat button, around line 353):

```swift
ToolbarItem(placement: .primaryAction) {
    Button {
        relatedPagesPresented.toggle()
    } label: {
        Label("Related Pages", systemImage: relatedPagesPresented
              ? "link.badge.plus" : "link")
    }
    .help(relatedPagesPresented ? "Hide related pages" : "Show related pages")
}
```

5. Trigger `relatedPages.load(...)` when a page is selected in the navigator (find the navigator selection handler, where `inspectorContext` is set — same place should also load related pages):

```swift
// After inspectorContext is set for a route-type selection:
if let siteID = site?.id, let path = selectedFile?.relativePath {
    Task { await relatedPages?.load(siteID: siteID, path: path) }
}
```

- [ ] **Step 3: Build and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build 2>&1 | tail -10`
Expected: builds clean

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/RelatedPagesPanel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#312): add RelatedPagesPanel UI + SiteWindow integration"
```

---

### Task 7: Full test pass + cleanup

**Files:**
- All files from Tasks 1–6

**Interfaces:**
- N/A — integration verification

- [ ] **Step 1: Run full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test 2>&1 | tail -15`
Expected: all tests pass (including the ~665 existing + new LinkGraph/SuggestLinks/FindLinkOpportunities tests)

- [ ] **Step 2: Run Xcode build for both targets**

```bash
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

Expected: build succeeds

- [ ] **Step 3: Verify new files are in Package.swift sources**

The new files are all in `Sources/AnglesiteCore/` and `Sources/AnglesiteApp/` which are already targets — no `Package.swift` changes needed. Confirm:

```bash
swift build 2>&1 | grep -i error | head -5
```

Expected: no errors

- [ ] **Step 4: Final commit if any cleanup was needed**

```bash
git add -A
git status  # verify only expected files
git commit -m "chore(#312): test pass + integration cleanup"
```
