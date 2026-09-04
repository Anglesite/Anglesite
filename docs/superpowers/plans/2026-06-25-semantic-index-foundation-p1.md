# Semantic Index Foundation (Plan A) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device semantic ranking layer on top of #329's lexical `SiteKnowledgeIndex`, and give the existing `SearchKnowledgeTool` a hybrid (lexical + semantic) mode.

**Architecture:** A `SemanticRanker` actor consumes `SiteKnowledgeIndex.documents(siteID:)`, embeds each document via a swappable `EmbeddingProvider`, caches the vectors in the package's `Config/` dir, and ranks by cosine similarity. Production embeddings come from Apple's `NaturalLanguage` framework on-device; a `FakeEmbeddingProvider` makes all ranking/caching logic CI-testable. The lexical index (#329) is unchanged.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`@Suite`/`#expect`), Apple `NaturalLanguage` (`NLContextualEmbedding` → `NLEmbedding` fallback), Foundation. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-06-25-semantic-link-assistant-design.md`

## Global Constraints

- **Hard prerequisite:** PR #329 (`SiteKnowledgeIndex`, `SearchKnowledgeTool`, `Document`) merged to `main`. This plan builds against those types as they land.
- **No external API / no network embedding service** — embeddings are 100% on-device (project strategy).
- **No third-party Swift dependencies** (Apple frameworks only).
- **Swift Testing**, not XCTest, for all new tests (`@Suite` / `@Test` / `#expect`).
- **Toolchain:** Xcode 27 / Swift 6.4. `swift test` requires `DEVELOPER_DIR` pointed at the Xcode 27 toolchain — prefix every test command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (adjust if your Xcode 27 lives elsewhere).
- **`Config/` is app-owned and never in git** — the embedding cache lives there.
- New AnglesiteCore types stay free of `FoundationModels` so they compile on CI; only files that already `#if compiler(>=6.4) import FoundationModels` (e.g. `SearchKnowledgeTool`) keep that guard. `NaturalLanguage` needs **no** compiler guard (it compiles on the macOS-15 CI runner; only the model *assets* may be absent at runtime).
- Run new-suite tests with `swift test --package-path . --filter <SuiteName>`.

---

### Task 1: `EmbeddingProvider` protocol + `FakeEmbeddingProvider`

**Files:**
- Create: `Sources/AnglesiteCore/EmbeddingProvider.swift`
- Test: `Tests/AnglesiteCoreTests/EmbeddingProviderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol EmbeddingProvider: Sendable { var dimension: Int { get }; func embed(_ text: String) async throws -> [Float] }`
  - `struct FakeEmbeddingProvider: EmbeddingProvider` with `init(dimension: Int = 8)`; deterministic, unit-normalized output; same text → identical vector; throws `EmbeddingError.emptyText` for blank input.
  - `enum EmbeddingError: Error, Equatable { case emptyText, modelUnavailable }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {
    @Test("fake provider is deterministic and unit-normalized")
    func deterministicNormalized() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let a = try await provider.embed("pricing plans for teams")
        let b = try await provider.embed("pricing plans for teams")
        #expect(a == b)
        #expect(a.count == 8)
        let magnitude = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.0001)
    }

    @Test("different text yields different vectors")
    func differentText() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let a = try await provider.embed("pricing")
        let b = try await provider.embed("about the team")
        #expect(a != b)
    }

    @Test("blank text throws emptyText")
    func blankThrows() async {
        let provider = FakeEmbeddingProvider(dimension: 8)
        await #expect(throws: EmbeddingError.emptyText) {
            _ = try await provider.embed("   ")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EmbeddingProvider`
Expected: FAIL — `cannot find 'FakeEmbeddingProvider' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// An error surfaced by an ``EmbeddingProvider``.
public enum EmbeddingError: Error, Equatable {
    /// The text to embed was empty or whitespace-only.
    case emptyText
    /// No on-device embedding model/asset is available at runtime.
    case modelUnavailable
}

/// Produces a fixed-length, unit-normalized embedding for a string. The single seam the
/// semantic ranker depends on, so the model choice (Apple NaturalLanguage in production, a
/// deterministic fake in tests) is swappable without touching ranking logic.
public protocol EmbeddingProvider: Sendable {
    /// The length of every vector this provider returns.
    var dimension: Int { get }
    /// Returns a unit-normalized embedding, or throws if the text is empty / no model is available.
    func embed(_ text: String) async throws -> [Float]
}

/// Deterministic embedding for tests: a stable bag-of-characters projection, unit-normalized.
/// Not semantically meaningful — only stable and content-sensitive, which is all the ranker,
/// cache, and incremental-update tests need.
public struct FakeEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int

    public init(dimension: Int = 8) {
        self.dimension = max(1, dimension)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        var vector = [Float](repeating: 0, count: dimension)
        for scalar in trimmed.unicodeScalars {
            vector[Int(scalar.value) % dimension] += 1
        }
        let magnitude = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.emptyText }
        return vector.map { $0 / magnitude }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter EmbeddingProvider`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/EmbeddingProvider.swift Tests/AnglesiteCoreTests/EmbeddingProviderTests.swift
git commit -m "feat(#312): EmbeddingProvider seam + deterministic FakeEmbeddingProvider"
```

---

### Task 2: `VectorMath` (cosine + stable hash helpers)

**Files:**
- Create: `Sources/AnglesiteCore/VectorMath.swift`
- Test: `Tests/AnglesiteCoreTests/VectorMathTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum VectorMath` with `static func cosine(_ a: [Float], _ b: [Float]) -> Float` (returns 0 for mismatched lengths or a zero vector) and `static func stableHash(_ text: String) -> String` (FNV-1a 64-bit, hex; identical across process runs — Swift's `Hasher` is per-run randomized and must not be used here).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("VectorMath")
struct VectorMathTests {
    @Test("cosine of identical unit vectors is 1")
    func identical() {
        #expect(abs(VectorMath.cosine([1, 0, 0], [1, 0, 0]) - 1.0) < 0.0001)
    }

    @Test("cosine of orthogonal vectors is 0")
    func orthogonal() {
        #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 0.0001)
    }

    @Test("cosine returns 0 for mismatched lengths or zero vectors")
    func degenerate() {
        #expect(VectorMath.cosine([1, 0], [1, 0, 0]) == 0)
        #expect(VectorMath.cosine([0, 0], [1, 0]) == 0)
    }

    @Test("stableHash is deterministic and content-sensitive")
    func stableHash() {
        #expect(VectorMath.stableHash("pricing") == VectorMath.stableHash("pricing"))
        #expect(VectorMath.stableHash("pricing") != VectorMath.stableHash("about"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter VectorMath`
Expected: FAIL — `cannot find 'VectorMath' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Small numeric helpers for the semantic index: cosine similarity and a process-stable hash.
public enum VectorMath {
    /// Cosine similarity. Returns 0 when lengths differ or either vector has zero magnitude,
    /// so degenerate inputs rank last instead of crashing.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA.squareRoot() * magB.squareRoot())
    }

    /// FNV-1a 64-bit hash as hex. Stable across process runs (unlike `Hasher`), so it is safe
    /// as a cache-invalidation key for embedded text.
    public static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter VectorMath`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/VectorMath.swift Tests/AnglesiteCoreTests/VectorMathTests.swift
git commit -m "feat(#312): VectorMath cosine + process-stable FNV-1a hash"
```

---

### Task 3: `SemanticIndexCache` (Config/ persistence of embeddings)

**Files:**
- Create: `Sources/AnglesiteCore/SemanticIndexCache.swift`
- Test: `Tests/AnglesiteCoreTests/SemanticIndexCacheTests.swift`

**Interfaces:**
- Consumes: `VectorMath` (indirectly, via callers).
- Produces:
  - `struct SemanticIndexCache.Entry: Codable, Equatable, Sendable { let docID: String; let contentHash: String; let dimension: Int; let vector: [Float] }`
  - `struct SemanticIndexCache` with `init(fileURL: URL)`, `func load(expectedDimension: Int) -> [String: Entry]` (returns `[docID: Entry]`; drops entries whose `dimension` ≠ `expectedDimension`; returns empty on missing/corrupt file), and `func save(_ entries: [String: Entry]) throws` (creates parent dirs; atomic write).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticIndexCache")
struct SemanticIndexCacheTests {
    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sem-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("caches/semantic-index.json")
    }

    @Test("save then load round-trips entries")
    func roundTrip() throws {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        let entry = SemanticIndexCache.Entry(docID: "s:doc:a", contentHash: "abc", dimension: 8, vector: [0, 1, 0, 0, 0, 0, 0, 0])
        try cache.save(["s:doc:a": entry])
        let loaded = cache.load(expectedDimension: 8)
        #expect(loaded == ["s:doc:a": entry])
    }

    @Test("load drops entries with mismatched dimension")
    func dropsWrongDimension() throws {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        let entry = SemanticIndexCache.Entry(docID: "s:doc:a", contentHash: "abc", dimension: 8, vector: [0, 1, 0, 0, 0, 0, 0, 0])
        try cache.save(["s:doc:a": entry])
        #expect(cache.load(expectedDimension: 16).isEmpty)
    }

    @Test("load returns empty for a missing file")
    func missingFile() {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        #expect(cache.load(expectedDimension: 8).isEmpty)
    }

    @Test("load returns empty for a corrupt file")
    func corruptFile() throws {
        let url = tempCacheURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(SemanticIndexCache(fileURL: url).load(expectedDimension: 8).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SemanticIndexCache`
Expected: FAIL — `cannot find 'SemanticIndexCache' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// On-disk cache of document embeddings, one file per site under the package's app-owned
/// `Config/caches/` (never in git). Embeddings are expensive to recompute; the lexical index
/// itself stays in-memory (see #329). Invalidation is by `contentHash` (caller-checked) and by
/// `dimension` (checked here on load).
public struct SemanticIndexCache: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let docID: String
        public let contentHash: String
        public let dimension: Int
        public let vector: [Float]

        public init(docID: String, contentHash: String, dimension: Int, vector: [Float]) {
            self.docID = docID
            self.contentHash = contentHash
            self.dimension = dimension
            self.vector = vector
        }
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads `[docID: Entry]`. Entries whose `dimension` differs from `expectedDimension` are
    /// dropped (the provider changed). A missing or corrupt file yields an empty map — never fatal.
    public func load(expectedDimension: Int) -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return [:]
        }
        var out: [String: Entry] = [:]
        for entry in entries where entry.dimension == expectedDimension {
            out[entry.docID] = entry
        }
        return out
    }

    /// Atomically writes the entries, creating the parent directory if needed.
    public func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries.values.sorted { $0.docID < $1.docID })
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SemanticIndexCache`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SemanticIndexCache.swift Tests/AnglesiteCoreTests/SemanticIndexCacheTests.swift
git commit -m "feat(#312): SemanticIndexCache — Config/ embedding persistence + invalidation"
```

---

### Task 4: `SemanticRanker` — sync / incremental embedding with cache

**Files:**
- Create: `Sources/AnglesiteCore/SemanticRanker.swift`
- Test: `Tests/AnglesiteCoreTests/SemanticRankerSyncTests.swift`

**Interfaces:**
- Consumes: `EmbeddingProvider`, `SemanticIndexCache`, `VectorMath.stableHash`, and `SiteKnowledgeIndex.Document` (from #329 — has `id`, `title`, `headings`, `excerptText`).
- Produces:
  - `actor SemanticRanker` with `init(provider: EmbeddingProvider, cache: SemanticIndexCache?)`.
  - `func sync(siteID: String, documents: [SiteKnowledgeIndex.Document]) async` — embeds each doc whose `contentHash` is new/changed (cache hit → reuse; miss → `provider.embed`), removes vectors for docs no longer present, writes the cache when a `cache` was supplied.
  - `func upsert(siteID: String, document: SiteKnowledgeIndex.Document) async` and `func remove(siteID: String, docID: String) async` for incremental updates.
  - `func vectorCount(siteID: String) async -> Int` (test/inspection helper).
  - Internal `static func embeddedText(for:) -> String` = `title` + `headings` joined + leading slice of `excerptText`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticRanker sync")
struct SemanticRankerSyncTests {
    /// Counts how many times embed() ran, so cache-hit behavior is observable.
    final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
        let dimension = 8
        private(set) var calls = 0
        func embed(_ text: String) async throws -> [Float] {
            calls += 1
            return try await FakeEmbeddingProvider(dimension: 8).embed(text)
        }
    }

    private func doc(_ id: String, title: String, body: String) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: id, siteID: "s", path: "\(id).md", kind: .page, title: title,
            frontmatter: [:], headings: [], internalLinks: [], excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("sync embeds each document once")
    func embedsEach() async {
        let provider = CountingProvider()
        let ranker = SemanticRanker(provider: provider, cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", title: "Pricing", body: "plans"),
            doc("b", title: "About", body: "team"),
        ])
        #expect(provider.calls == 2)
        #expect(await ranker.vectorCount(siteID: "s") == 2)
    }

    @Test("re-sync with unchanged content does not re-embed")
    func cachesUnchanged() async {
        let provider = CountingProvider()
        let ranker = SemanticRanker(provider: provider, cache: nil)
        let docs = [doc("a", title: "Pricing", body: "plans")]
        await ranker.sync(siteID: "s", documents: docs)
        await ranker.sync(siteID: "s", documents: docs)
        #expect(provider.calls == 1)
    }

    @Test("sync drops vectors for removed documents")
    func dropsRemoved() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [doc("a", title: "A", body: "x"), doc("b", title: "B", body: "y")])
        await ranker.sync(siteID: "s", documents: [doc("a", title: "A", body: "x")])
        #expect(await ranker.vectorCount(siteID: "s") == 1)
    }

    @Test("cache lets a fresh ranker skip embedding")
    func warmCacheSkipsEmbed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sem-\(UUID().uuidString)/caches/semantic-index.json")
        let docs = [doc("a", title: "Pricing", body: "plans")]
        let first = SemanticRanker(provider: CountingProvider(), cache: SemanticIndexCache(fileURL: url))
        await first.sync(siteID: "s", documents: docs)

        let warmProvider = CountingProvider()
        let second = SemanticRanker(provider: warmProvider, cache: SemanticIndexCache(fileURL: url))
        await second.sync(siteID: "s", documents: docs)
        #expect(warmProvider.calls == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SemanticRanker sync"`
Expected: FAIL — `cannot find 'SemanticRanker' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// On-device semantic ranking layer over #329's lexical ``SiteKnowledgeIndex``. Holds one
/// embedding vector per document, persisted via ``SemanticIndexCache``. The lexical index is
/// untouched; this is purely additive.
public actor SemanticRanker {
    private struct Stored {
        let contentHash: String
        let vector: [Float]
    }

    private let provider: EmbeddingProvider
    private let cache: SemanticIndexCache?
    /// `[siteID: [docID: Stored]]`.
    private var vectorsBySite: [String: [String: Stored]] = [:]

    public init(provider: EmbeddingProvider, cache: SemanticIndexCache?) {
        self.provider = provider
        self.cache = cache
    }

    /// Text fed to the embedder: title + headings + a leading slice of the body. Document-level
    /// granularity (v0); chunking is a later extension.
    static func embeddedText(for document: SiteKnowledgeIndex.Document) -> String {
        var parts: [String] = []
        if let title = document.title, !title.isEmpty { parts.append(title) }
        if !document.headings.isEmpty { parts.append(document.headings.joined(separator: " ")) }
        parts.append(String(document.excerptText.prefix(2000)))
        return parts.joined(separator: "\n")
    }

    public func sync(siteID: String, documents: [SiteKnowledgeIndex.Document]) async {
        // Seed from the cold cache on first touch of this site.
        if vectorsBySite[siteID] == nil, let cache {
            let entries = cache.load(expectedDimension: provider.dimension)
            vectorsBySite[siteID] = entries.mapValues { Stored(contentHash: $0.contentHash, vector: $0.vector) }
        }
        var current = vectorsBySite[siteID] ?? [:]
        var next: [String: Stored] = [:]
        for document in documents {
            let hash = VectorMath.stableHash(Self.embeddedText(for: document))
            if let existing = current[document.id], existing.contentHash == hash {
                next[document.id] = existing
                continue
            }
            if let vector = try? await provider.embed(Self.embeddedText(for: document)) {
                next[document.id] = Stored(contentHash: hash, vector: vector)
            }
        }
        vectorsBySite[siteID] = next
        current = next
        persist(siteID: siteID)
    }

    public func upsert(siteID: String, document: SiteKnowledgeIndex.Document) async {
        let hash = VectorMath.stableHash(Self.embeddedText(for: document))
        if let existing = vectorsBySite[siteID]?[document.id], existing.contentHash == hash { return }
        guard let vector = try? await provider.embed(Self.embeddedText(for: document)) else { return }
        vectorsBySite[siteID, default: [:]][document.id] = Stored(contentHash: hash, vector: vector)
        persist(siteID: siteID)
    }

    public func remove(siteID: String, docID: String) async {
        vectorsBySite[siteID]?[docID] = nil
        persist(siteID: siteID)
    }

    public func vectorCount(siteID: String) -> Int {
        vectorsBySite[siteID]?.count ?? 0
    }

    private func persist(siteID: String) {
        guard let cache, let stored = vectorsBySite[siteID] else { return }
        let entries = stored.mapValues {
            SemanticIndexCache.Entry(docID: "", contentHash: $0.contentHash, dimension: provider.dimension, vector: $0.vector)
        }
        // Re-stamp docID from the key (Entry needs it for round-trip).
        var keyed: [String: SemanticIndexCache.Entry] = [:]
        for (docID, entry) in entries {
            keyed[docID] = SemanticIndexCache.Entry(docID: docID, contentHash: entry.contentHash, dimension: entry.dimension, vector: entry.vector)
        }
        try? cache.save(keyed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SemanticRanker sync"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SemanticRanker.swift Tests/AnglesiteCoreTests/SemanticRankerSyncTests.swift
git commit -m "feat(#312): SemanticRanker sync — incremental embedding with Config/ cache"
```

---

### Task 5: `SemanticRanker` — ranking queries + hybrid blend

**Files:**
- Modify: `Sources/AnglesiteCore/SemanticRanker.swift`
- Test: `Tests/AnglesiteCoreTests/SemanticRankerRankTests.swift`

**Interfaces:**
- Consumes: the `vectorsBySite` store from Task 4, `VectorMath.cosine`, `EmbeddingProvider`.
- Produces (added to `SemanticRanker`):
  - `struct Ranked: Sendable, Equatable { let docID: String; let score: Float }`
  - `func related(siteID: String, toDocID: String, limit: Int) async -> [Ranked]` — cosine of the source doc's vector vs every other same-site vector, descending, self excluded.
  - `func search(siteID: String, queryText: String, limit: Int) async -> [Ranked]` — embeds `queryText`, ranks by cosine.
  - `static func blend(lexical: [String: Double], semantic: [String: Double], semanticWeight: Double) -> [String: Double]` — min-max normalizes each map to 0…1 and returns `semanticWeight * sem + (1 - semanticWeight) * lex` per docID (union of keys; a missing side counts 0).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticRanker rank")
struct SemanticRankerRankTests {
    private func doc(_ id: String, body: String) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: id, siteID: "s", path: "\(id).md", kind: .page, title: id,
            frontmatter: [:], headings: [], internalLinks: [], excerptText: body,
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("related ranks the most similar document first and excludes self")
    func related() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", body: "pricing plans pricing plans"),
            doc("b", body: "pricing plans for teams"),   // close to a
            doc("c", body: "zzzz qqqq wholly different"), // far from a
        ])
        let ranked = await ranker.related(siteID: "s", toDocID: "a", limit: 5)
        #expect(!ranked.contains { $0.docID == "a" })
        #expect(ranked.first?.docID == "b")
    }

    @Test("search ranks by similarity to the query text")
    func search() async {
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: [
            doc("a", body: "pricing plans for teams"),
            doc("b", body: "completely unrelated content here"),
        ])
        let ranked = await ranker.search(siteID: "s", queryText: "pricing plans for teams", limit: 5)
        #expect(ranked.first?.docID == "a")
    }

    @Test("blend normalizes and weights both signals")
    func blend() {
        let result = SemanticRanker.blend(
            lexical: ["a": 10, "b": 0],
            semantic: ["a": 0, "b": 1],
            semanticWeight: 0.5)
        // a: 0.5*0 + 0.5*1 = 0.5 ; b: 0.5*1 + 0.5*0 = 0.5
        #expect(abs((result["a"] ?? -1) - 0.5) < 0.0001)
        #expect(abs((result["b"] ?? -1) - 0.5) < 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SemanticRanker rank"`
Expected: FAIL — `value of type 'SemanticRanker' has no member 'related'`.

- [ ] **Step 3: Write minimal implementation** — append to `SemanticRanker.swift`, inside the actor for the instance methods and as a `nonisolated static` for `blend`:

```swift
    public struct Ranked: Sendable, Equatable {
        public let docID: String
        public let score: Float
        public init(docID: String, score: Float) { self.docID = docID; self.score = score }
    }

    public func related(siteID: String, toDocID: String, limit: Int) -> [Ranked] {
        guard let store = vectorsBySite[siteID], let source = store[toDocID] else { return [] }
        return rank(store: store, against: source.vector, excluding: toDocID, limit: limit)
    }

    public func search(siteID: String, queryText: String, limit: Int) async -> [Ranked] {
        guard let store = vectorsBySite[siteID], let queryVector = try? await provider.embed(queryText) else { return [] }
        return rank(store: store, against: queryVector, excluding: nil, limit: limit)
    }

    private func rank(store: [String: Stored], against query: [Float], excluding: String?, limit: Int) -> [Ranked] {
        store.compactMap { docID, stored -> Ranked? in
            if docID == excluding { return nil }
            return Ranked(docID: docID, score: VectorMath.cosine(query, stored.vector))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.docID < $1.docID }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// Min-max normalizes each signal to 0…1, then returns the weighted sum per docID over the
    /// union of keys (a docID absent from one side contributes 0 there).
    public nonisolated static func blend(
        lexical: [String: Double], semantic: [String: Double], semanticWeight: Double
    ) -> [String: Double] {
        func normalize(_ map: [String: Double]) -> [String: Double] {
            guard let lo = map.values.min(), let hi = map.values.max(), hi > lo else {
                return map.mapValues { _ in map.isEmpty ? 0 : 1 }
            }
            return map.mapValues { ($0 - lo) / (hi - lo) }
        }
        let lex = normalize(lexical), sem = normalize(semantic)
        let w = min(max(semanticWeight, 0), 1)
        var out: [String: Double] = [:]
        for docID in Set(lex.keys).union(sem.keys) {
            out[docID] = w * (sem[docID] ?? 0) + (1 - w) * (lex[docID] ?? 0)
        }
        return out
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SemanticRanker rank"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SemanticRanker.swift Tests/AnglesiteCoreTests/SemanticRankerRankTests.swift
git commit -m "feat(#312): SemanticRanker related/search queries + hybrid blend"
```

---

### Task 6: `NLEmbeddingProvider` (production, on-device)

**Files:**
- Create: `Sources/AnglesiteCore/NLEmbeddingProvider.swift`
- Test: `Tests/AnglesiteCoreTests/NLEmbeddingProviderTests.swift`

**Interfaces:**
- Consumes: `EmbeddingProvider`, `NaturalLanguage`.
- Produces: `struct NLEmbeddingProvider: EmbeddingProvider` with `init?(language: NLLanguage = .english)` (fails init if no sentence-embedding model is available, so callers fall back to lexical-only). `dimension` reflects the loaded model; `embed` returns the model vector unit-normalized, throwing `EmbeddingError.emptyText` for blank input.

> Rationale: `NLEmbedding.sentenceEmbedding` is synchronous, asset-free, and available on the CI runner, so it is the dependable production default. `NLContextualEmbedding` (higher quality, multilingual) is a later swap behind the same protocol — deferred so this task stays CI-verifiable. The smoke test self-skips when no model is present.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import NaturalLanguage
import Testing
@testable import AnglesiteCore

@Suite("NLEmbeddingProvider")
struct NLEmbeddingProviderTests {
    @Test("when a model is available, embeddings are unit-normalized and similar text ranks closer")
    func embeds() async throws {
        guard let provider = NLEmbeddingProvider() else {
            // No sentence-embedding asset on this host (e.g. minimal CI image) — nothing to verify.
            return
        }
        let pricing = try await provider.embed("our pricing and subscription plans")
        let plans = try await provider.embed("subscription pricing tiers")
        let weather = try await provider.embed("today's weather forecast")
        let magnitude = (pricing.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.001)
        #expect(VectorMath.cosine(pricing, plans) > VectorMath.cosine(pricing, weather))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NLEmbeddingProvider`
Expected: FAIL — `cannot find 'NLEmbeddingProvider' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import NaturalLanguage

/// Production ``EmbeddingProvider`` backed by Apple's on-device `NLEmbedding.sentenceEmbedding`.
/// Synchronous and asset-light, so it works without a network embedding service (project
/// strategy). Returns `nil` from init when no model is available, letting callers degrade to
/// lexical-only ranking.
public struct NLEmbeddingProvider: EmbeddingProvider {
    private let embedding: NLEmbedding
    public let dimension: Int

    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = embedding
        self.dimension = embedding.dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }
        guard let raw = embedding.vector(for: trimmed) else { throw EmbeddingError.modelUnavailable }
        let floats = raw.map { Float($0) }
        let magnitude = (floats.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard magnitude > 0 else { throw EmbeddingError.modelUnavailable }
        return floats.map { $0 / magnitude }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter NLEmbeddingProvider`
Expected: PASS (1 test — verifies real ranking if a model is present, no-ops otherwise).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NLEmbeddingProvider.swift Tests/AnglesiteCoreTests/NLEmbeddingProviderTests.swift
git commit -m "feat(#312): NLEmbeddingProvider — on-device NaturalLanguage embeddings"
```

---

### Task 7: `SearchKnowledgeTool` hybrid (lexical + semantic) mode

**Files:**
- Modify: `Sources/AnglesiteCore/SearchKnowledgeTool.swift`
- Test: `Tests/AnglesiteCoreTests/SearchKnowledgeToolHybridTests.swift`

**Interfaces:**
- Consumes: `SiteKnowledgeIndex` (lexical results), `SemanticRanker.search`, `SemanticRanker.blend`.
- Produces: `SearchKnowledgeTool.init(index:siteID:ranker:)` gains an optional `ranker: SemanticRanker? = nil`. When a ranker is present, `call` blends lexical scores (from `index.search`) with semantic scores (from `ranker.search`) via `SemanticRanker.blend(..., semanticWeight: 0.6)`, re-ordering the lexical `SearchResult`s by blended score before formatting. When `ranker == nil` (or it returns nothing), behavior is byte-for-byte the existing lexical output.

> Keep `@Generable Arguments`, the empty-query guard, and the output string format from #329 unchanged — only the ordering of results changes when a ranker is attached.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SearchKnowledgeTool hybrid")
struct SearchKnowledgeToolHybridTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("khybrid-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("hybrid mode returns results and does not crash with a fake provider")
    func hybridRanks() async {
        let root = makeSite([
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nSubscription plans for teams.",
            "src/pages/about.astro": "---\ntitle: About\n---\n# About\nOur team story.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        await ranker.sync(siteID: "s", documents: await index.documents(siteID: "s"))

        let tool = SearchKnowledgeTool(index: index, siteID: "s", ranker: ranker)
        let output = try! await tool.call(arguments: .init(query: "subscription pricing plans"))
        #expect(output.contains("pricing.astro"))
    }

    @Test("without a ranker, output matches the lexical-only tool")
    func lexicalFallback() async {
        let root = makeSite(["src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nPlans."])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let lexicalOnly = SearchKnowledgeTool(index: index, siteID: "s")
        let output = try! await lexicalOnly.call(arguments: .init(query: "pricing"))
        #expect(output.contains("pricing.astro"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SearchKnowledgeTool hybrid"`
Expected: FAIL — `extra argument 'ranker' in call`.

- [ ] **Step 3: Write minimal implementation** — update the stored props, init, and `call` in `SearchKnowledgeTool.swift`:

```swift
    private let index: SiteKnowledgeIndex
    private let siteID: String
    private let ranker: SemanticRanker?

    public init(index: SiteKnowledgeIndex, siteID: String, ranker: SemanticRanker? = nil) {
        self.index = index
        self.siteID = siteID
        self.ranker = ranker
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Provide a project search query."
        }
        var results = await index.search(siteID: siteID, query: query, options: .init(limit: 6))
        if let ranker {
            let semantic = await ranker.search(siteID: siteID, queryText: query, limit: 50)
            if !semantic.isEmpty {
                let lexicalScores = Dictionary(results.map { ($0.document.id, $0.score) }, uniquingKeysWith: max)
                let semanticScores = Dictionary(semantic.map { ($0.docID, Double($0.score)) }, uniquingKeysWith: max)
                let blended = SemanticRanker.blend(lexical: lexicalScores, semantic: semanticScores, semanticWeight: 0.6)
                results = results.sorted {
                    (blended[$0.document.id] ?? 0) != (blended[$1.document.id] ?? 0)
                        ? (blended[$0.document.id] ?? 0) > (blended[$1.document.id] ?? 0)
                        : $0.document.path < $1.document.path
                }
            }
        }
        guard !results.isEmpty else { return "No matching project context." }

        return results.map { result in
            let lineLabel: String
            if let range = result.lineRange {
                lineLabel = ":\(range.lowerBound)"
            } else {
                lineLabel = ""
            }
            let title = result.document.title.map { " - \($0)" } ?? ""
            return """
            \(result.document.kind.rawValue.uppercased())  \(result.document.path)\(lineLabel)\(title)
            \(result.excerpt)
            """
        }.joined(separator: "\n\n")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "SearchKnowledgeTool"`
Expected: PASS (both the new hybrid suite and #329's existing `SearchKnowledgeTool` coverage in `OnDeviceToolsTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SearchKnowledgeTool.swift Tests/AnglesiteCoreTests/SearchKnowledgeToolHybridTests.swift
git commit -m "feat(#312): SearchKnowledgeTool hybrid lexical+semantic ranking"
```

---

### Task 8: Wire `SemanticRanker` through the runtime

**Files:**
- Modify: `Sources/AnglesiteCore/LocalSiteRuntime.swift` (construct + own a `SemanticRanker` next to the `SiteKnowledgeIndex`; call `ranker.sync` after the index `rebuild`, and `unload`/clear on site close)
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (accept an optional `semanticRanker` and pass it into `SearchKnowledgeTool(index:siteID:ranker:)` at line ~342)
- Modify: `Sources/AnglesiteApp/PreviewModel.swift` and `Sources/AnglesiteApp/SiteWindow.swift` (thread the ranker through exactly where #329 threads the `knowledgeIndex`)
- Test: `Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift` (extend the existing assistant-wiring test)

**Interfaces:**
- Consumes: `SemanticRanker`, `NLEmbeddingProvider`, `SemanticIndexCache`, `SiteKnowledgeIndex`, `AnglesitePackage` (for the `Config/` dir → cache file URL).
- Produces: a live `SemanticRanker` per open site, kept in sync with the lexical index, attached to the on-device tool. The cache file URL is `<package>/Config/caches/semantic-index.json` via `AnglesitePackage`'s config-directory accessor.

- [ ] **Step 1: Write the failing test** — extend `OnDeviceToolsTests` to assert the assistant still advertises `searchKnowledge` when a ranker is attached:

```swift
@Test("assistant attaches searchKnowledge tool when a semantic ranker is present")
func attachesKnowledgeToolWithRanker() async {
    let index = SiteKnowledgeIndex()
    let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
    let assistant = FoundationModelAssistant(knowledgeIndex: index, semanticRanker: ranker)
    #expect(assistant.capabilities.supportsTools)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter OnDeviceTools`
Expected: FAIL — `extra argument 'semanticRanker' in call`.

- [ ] **Step 3: Write minimal implementation**

In `FoundationModelAssistant.swift`: add `private let semanticRanker: SemanticRanker?`, add `semanticRanker: SemanticRanker? = nil` to `init` (store it), and change the knowledge-tool construction:

```swift
        if let knowledgeIndex {
            tools.append(SearchKnowledgeTool(index: knowledgeIndex, siteID: context.siteID, ranker: semanticRanker))
        }
```

In `LocalSiteRuntime.swift`, alongside the existing `SiteKnowledgeIndex` lifecycle, construct the ranker once per runtime:

```swift
        let cacheURL = package.configDirectory
            .appendingPathComponent("caches/semantic-index.json")
        let ranker = SemanticRanker(
            provider: NLEmbeddingProvider() ?? FakeEmbeddingProvider(),
            cache: SemanticIndexCache(fileURL: cacheURL))
```

and after the knowledge index `rebuild` completes:

```swift
        await ranker.sync(siteID: siteID, documents: await knowledgeIndex.documents(siteID: siteID))
```

Thread `ranker` into `FoundationModelAssistant(...)` and through `PreviewModel` / `SiteWindow` at the same call sites that already pass `knowledgeIndex` (follow #329's diff in those two files). Use `package.configDirectory` if it exists; otherwise the package's `Config/` URL accessor from `AnglesitePackage` — confirm the exact name when implementing (`AnglesitePackage`/`SiteStore.Site` exposes `configDirectory`).

- [ ] **Step 4: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS — all prior suites plus the new `OnDeviceTools` assertion. Then build the app to confirm the App-target wiring compiles:
`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
(run `xcodegen generate` + `scripts/copy-plugin.sh` first if in a fresh worktree).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LocalSiteRuntime.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteCoreTests/OnDeviceToolsTests.swift
git commit -m "feat(#312): wire SemanticRanker through runtime + on-device assistant"
```

---

## Self-Review

**Spec coverage (Plan A scope):**
- `EmbeddingProvider` seam + on-device engine → Tasks 1, 6. ✅
- `SemanticRanker` consuming `SiteKnowledgeIndex.documents`, document-level granularity with chunk seam noted → Tasks 4, 5. ✅
- `Config/` embedding cache, content-hash + dimension invalidation, in-memory lexical untouched → Task 3, used in 4 & 8. ✅
- Hybrid (lexical + semantic) ranking → Task 5 (`blend`), Task 7 (tool). ✅
- `SearchKnowledgeTool` semantic upgrade consumer → Task 7. ✅
- Graceful degradation to lexical when no model → `NLEmbeddingProvider?` init + `try?` in ranker + `ranker == nil` path in tool (Tasks 6, 4, 7). ✅
- Runtime wiring mirroring #329 → Task 8. ✅
- **Deferred to Plan B (Related-Pages panel + insertion):** `LinkGraph`, `RelatedPagesProvider`, the SwiftUI panel, link insertion via `EditRouter`. Out of this plan by design.

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step is complete. The one runtime-name caveat (Task 8: confirm `configDirectory` accessor) is an explicit verify-the-name instruction against a known type, not a missing implementation. ✅

**Type consistency:** `EmbeddingProvider.embed`/`dimension`, `EmbeddingError.{emptyText,modelUnavailable}`, `SemanticIndexCache.Entry{docID,contentHash,dimension,vector}`, `SemanticRanker.{sync,upsert,remove,related,search,blend,vectorCount,Ranked,Stored,embeddedText}`, `SearchKnowledgeTool.init(index:siteID:ranker:)`, `FoundationModelAssistant(... semanticRanker:)` — all consistent across tasks. ✅

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-25-semantic-index-foundation-p1.md`.
