import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("IncrementalReindex")
struct IncrementalReindexTests {

    private let exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    @Test("relativePOSIXPath returns nil for paths outside the root")
    func relativePathOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/tmp/site/src/x.astro"), under: root) == "src/x.astro")
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/etc/passwd"), under: root) == nil)
    }

    @Test("isSkipped matches build/dependency directories")
    func skippedDirs() {
        #expect(SiteIndexPaths.isSkipped(relativePath: "node_modules/pkg/index.js"))
        #expect(SiteIndexPaths.isSkipped(relativePath: "dist/index.html"))
        #expect(SiteIndexPaths.isSkipped(relativePath: ".git/HEAD"))
        #expect(!SiteIndexPaths.isSkipped(relativePath: "src/pages/index.astro"))
    }

    @Test("apply upserts a newly created file into the index")
    func applyUpsertsNewFile() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" } == false)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        await KnowledgeReindex.apply(.init(paths: [added], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" })
    }

    @Test("apply classifies a batch of new blog/ entries as posts on a template-style config (#1725)")
    func applyClassifiesBlogBatchAsPosts() async {
        let root = try! writeSiteTree(prefix: "reindex", [
            "src/content.config.ts": """
            const blog = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
            const products = defineCollection({ type: "content", schema: z.object({ name: z.string() }) });
            export const collections = { blog, products };
            """,
            "src/pages/index.astro": "---\ntitle: Home\n---\n# Home",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        // Several files land in one batch, as after a git pull — the batch path resolves the
        // post collections once and must classify every file with the same rules as `rebuild`.
        let added = ["src/content/blog/one.md", "src/content/blog/two.md", "src/content/products/widget.md"]
        for path in added {
            let url = root.appendingPathComponent(path)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("---\ntitle: \(path)\n---\nbody".utf8).write(to: url)
        }
        await KnowledgeReindex.apply(.init(paths: added.map { root.appendingPathComponent($0) }, needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.document(siteID: "s", relativePath: "src/content/blog/one.md")?.kind == .post)
        #expect(await index.document(siteID: "s", relativePath: "src/content/blog/two.md")?.kind == .post)
        #expect(await index.document(siteID: "s", relativePath: "src/content/products/widget.md")?.kind == .content)
    }

    @Test("apply removes a deleted file from the index")
    func applyRemovesDeletedFile() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/gone.astro": "---\ntitle: Gone\n---\nbody"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" })

        let gone = root.appendingPathComponent("src/pages/gone.astro")
        await KnowledgeReindex.apply(.init(paths: [gone], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: { _ in false })

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" } == false)
    }

    @Test("apply ignores skipped-directory paths")
    func applyIgnoresSkippedDirs() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let before = await index.documents(siteID: "s").count

        let noise = root.appendingPathComponent("node_modules/pkg/index.js")
        try! FileManager.default.createDirectory(at: noise.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("module.exports = {}".utf8).write(to: noise)
        await KnowledgeReindex.apply(.init(paths: [noise], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").count == before)
    }

    @Test("apply with needsFullRescan rebuilds and picks up files absent from the batch")
    func applyFullRescan() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        // A file added on disk but NOT named in the batch — only a full rebuild finds it.
        let surprise = root.appendingPathComponent("src/pages/surprise.astro")
        try! Data("---\ntitle: Surprise\n---\nbody".utf8).write(to: surprise)
        await KnowledgeReindex.apply(.init(paths: [], needsFullRescan: true),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/surprise.astro" })
    }

    // MARK: - Semantic ranker reconciliation (#383)

    /// Wraps the deterministic fake to count embed() calls, so re-embedding is observable.
    /// `@unchecked Sendable` is safe: `NSLock` protects `_calls` across actor hops. Sequential
    /// embedding means the lock is never contended in practice, but the lock — not the call
    /// order — is the soundness argument.
    final class CountingFake: EmbeddingProvider, @unchecked Sendable {
        let dimension = 8
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func embed(_ text: String) async throws -> [Float] {
            lock.lock(); _calls += 1; lock.unlock()
            return try await FakeEmbeddingProvider(dimension: 8).embed(text)
        }
    }

    /// Build an index + ranker both seeded to the same on-disk state (mirrors site-open:
    /// `rebuild` then `sync`), so subsequent `apply` calls exercise the incremental path.
    private func seededIndexAndRanker(
        _ root: URL, siteID: String = "s", provider: EmbeddingProvider = FakeEmbeddingProvider(dimension: 8)
    ) async -> (SiteKnowledgeIndex, SemanticRanker) {
        let index = SiteKnowledgeIndex()
        let ranker = SemanticRanker(provider: provider, cache: nil)
        await index.rebuild(siteID: siteID, projectRoot: root)
        await ranker.sync(siteID: siteID, documents: await index.documents(siteID: siteID))
        return (index, ranker)
    }

    @Test("apply embeds a newly created file into the ranker")
    func applyUpsertsRankerForNewFile() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let (index, ranker) = await seededIndexAndRanker(root)
        #expect(await ranker.vectorCount(siteID: "s") == 1)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        await KnowledgeReindex.apply(.init(paths: [added], needsFullRescan: false),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await ranker.vectorCount(siteID: "s") == 2)
    }

    @Test("apply drops a deleted file's vector from the ranker")
    func applyRemovesRankerVectorForDeletedFile() async {
        let root = try! writeSiteTree(prefix: "reindex", [
            "src/pages/index.astro": "---\ntitle: Home\n---\n# Home",
            "src/pages/gone.astro": "---\ntitle: Gone\n---\nbody",
        ])
        let (index, ranker) = await seededIndexAndRanker(root)
        #expect(await ranker.vectorCount(siteID: "s") == 2)

        let gone = root.appendingPathComponent("src/pages/gone.astro")
        try! FileManager.default.removeItem(at: gone)
        await KnowledgeReindex.apply(.init(paths: [gone], needsFullRescan: false),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await ranker.vectorCount(siteID: "s") == 1)
    }

    @Test("apply re-embeds a changed file so the ranker reflects new content")
    func applyReembedsChangedFile() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let provider = CountingFake()
        let (index, ranker) = await seededIndexAndRanker(root, provider: provider)
        let baseline = provider.calls

        let changed = root.appendingPathComponent("src/pages/index.astro")
        try! Data("---\ntitle: Home Renamed\n---\n# Totally different body".utf8).write(to: changed)
        await KnowledgeReindex.apply(.init(paths: [changed], needsFullRescan: false),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(provider.calls == baseline + 1)
        #expect(await ranker.vectorCount(siteID: "s") == 1)
    }

    @Test("apply does not re-embed when a touched file's content is unchanged")
    func applySkipsReembedForUnchangedFile() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let provider = CountingFake()
        let (index, ranker) = await seededIndexAndRanker(root, provider: provider)
        let baseline = provider.calls

        let touched = root.appendingPathComponent("src/pages/index.astro")
        await KnowledgeReindex.apply(.init(paths: [touched], needsFullRescan: false),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        // SemanticRanker.upsert skips re-embedding when the document's content hash is unchanged;
        // KnowledgeReindex itself does not dedupe by content. This verifies that guarantee holds
        // end-to-end through the reindex path (it would break if the ranker lost its hash check).
        #expect(provider.calls == baseline)
    }

    @Test("apply with needsFullRescan re-syncs the ranker with files absent from the batch")
    func applyFullRescanResyncsRanker() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let (index, ranker) = await seededIndexAndRanker(root)
        #expect(await ranker.vectorCount(siteID: "s") == 1)

        let surprise = root.appendingPathComponent("src/pages/surprise.astro")
        try! Data("---\ntitle: Surprise\n---\nbody".utf8).write(to: surprise)
        await KnowledgeReindex.apply(.init(paths: [], needsFullRescan: true),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await ranker.vectorCount(siteID: "s") == 2)
    }

    @Test("apply drops a stale ranker vector when a present file is no longer indexable")
    func applyRemovesRankerVectorForNonIndexableFile() async {
        // A file exists on disk (so fileExists is true and it isn't in a skipped dir) but its kind
        // is not indexed (.png) — `upsertFile` runs yet persists no document. Exercises the branch
        // where the ranker still holds a vector for that path and must drop it.
        let root = try! writeSiteTree(prefix: "reindex", [:])
        let pngPath = "assets/logo.png"
        let pngURL = root.appendingPathComponent(pngPath)
        try! FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("not really a png".utf8).write(to: pngURL)

        let index = SiteKnowledgeIndex()
        let ranker = SemanticRanker(provider: FakeEmbeddingProvider(dimension: 8), cache: nil)
        // Simulate a stale vector lingering for this path's doc ID (e.g. it was indexable before).
        let staleDoc = SiteKnowledgeIndex.Document(
            id: SiteKnowledgeIndex.documentID(siteID: "s", relativePath: pngPath),
            siteID: "s", path: pngPath, kind: .other, title: "Logo",
            frontmatter: [:], headings: [], internalLinks: [], excerptText: "logo",
            lastModified: Date(timeIntervalSince1970: 0))
        await ranker.upsert(siteID: "s", document: staleDoc)
        #expect(await ranker.vectorCount(siteID: "s") == 1)

        await KnowledgeReindex.apply(.init(paths: [pngURL], needsFullRescan: false),
                                     to: index, ranker: ranker, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await ranker.vectorCount(siteID: "s") == 0)
        #expect(await index.document(siteID: "s", relativePath: pngPath) == nil)
    }

    @Test("apply with a nil ranker still updates the index (back-compat)")
    func applyWithNilRankerUpdatesIndex() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        await KnowledgeReindex.apply(.init(paths: [added], needsFullRescan: false),
                                     to: index, ranker: nil, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" })
    }

    @Test("apply deduplicates repeated paths within a single batch")
    func applyDeduplicatesRepeatedPaths() async {
        let root = try! writeSiteTree(prefix: "reindex", ["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)

        // Count fileExists probes: dedup means the repeated path is reconciled once, not 3×.
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
        }
        let counter = Counter()
        let countingExists: @Sendable (URL) -> Bool = { url in
            counter.bump()
            return FileManager.default.fileExists(atPath: url.path)
        }

        await KnowledgeReindex.apply(.init(paths: [added, added, added], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: countingExists)

        #expect(counter.n == 1)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" })
    }
}
