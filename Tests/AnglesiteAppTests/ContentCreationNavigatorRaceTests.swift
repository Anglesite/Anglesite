// Tests/AnglesiteAppTests/ContentCreationNavigatorRaceTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// #1420: "New Post / New Component / Duplicate don't appear in Navigator or preview after
/// creation." The issue thread's live hypothesis for the Navigator half was a race between the
/// file write and `SiteContentGraph`'s own async file-watcher/rescan. Reading `ContentScanner`,
/// `SiteContentGraph`, and `ContentCreationWorkflow` shows no such watcher exists — every rescan
/// is a synchronous, `await`ed, generation-fenced call (`ContentCreationWorkflow.
/// refreshContentGraph`, #666), and `SiteNavigatorModel.refreshNow()` reads the graph back
/// directly. This test exercises that exact chain end-to-end with real (non-fake) types — the
/// same wiring `SiteWindowModel.createPost`/`refreshAfterContentMutation` drive in production,
/// minus the `SiteStore.shared` registry lookup — to settle whether the Navigator half of #1420
/// still reproduces against current code, or whether (per PR #1425's own "isolated integration
/// test" claim) that plumbing already works and the remaining bug is elsewhere.
@Suite("Content creation → Navigator race (#1420)")
@MainActor
struct ContentCreationNavigatorRaceTests {
    private func flatten(_ nodes: [URLTreeNode]) -> [URLTreeNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    @Test("a post created through the real workflow appears in the Navigator after refreshNow(), no manual delay needed")
    func createdPostAppearsInNavigatorImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-nav-race-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Test.anglesite/Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        let ops = NativeContentOperations(
            siteDirectory: { _ in sourceDirectory },
            gitCommit: { _, _, _ in "deadbeef" }
        )
        let workflow = ContentCreationWorkflow(
            operations: ops,
            contentGraph: graph,
            siteDirectory: { _ in sourceDirectory }
        )

        let navigator = SiteNavigatorModel(graph: graph)
        navigator.start(
            site: CurrentSite(id: "site-a", packageURL: root.appendingPathComponent("Test.anglesite"),
                               sourceDirectory: sourceDirectory)
        )
        // `buildSiteURLTree` returns `[]` for a site with no pages/posts (SiteURLTree.swift:62), so
        // a freshly created empty `Source/` never populates `nodes` at all — nothing to wait for here.
        #expect(flatten(navigator.nodes).contains { $0.title == "Retest Refresh Post" } == false)

        let result = await workflow.createPost(siteID: "site-a", title: "Retest Refresh Post", collection: nil, slug: nil)
        guard case .created = result else {
            Issue.record("expected .created, got \(result)")
            return
        }

        // Mirrors `SiteWindowModel.refreshAfterContentMutation()`'s `navigator?.refreshNow()` call
        // — the force-refresh #586/#608 added specifically to close the gap between the graph
        // mutation landing and the Navigator's own long-running stream-consumer task draining it.
        await navigator.refreshNow()

        #expect(flatten(navigator.nodes).contains { $0.title == "Retest Refresh Post" })
    }

    @Test("a post created through the real workflow appears in the Navigator via its own change-stream, with no explicit refreshNow() at all")
    func createdPostAppearsInNavigatorViaChangeStreamAlone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-nav-race-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Test.anglesite/Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = SiteContentGraph()
        let ops = NativeContentOperations(
            siteDirectory: { _ in sourceDirectory },
            gitCommit: { _, _, _ in "deadbeef" }
        )
        let workflow = ContentCreationWorkflow(
            operations: ops,
            contentGraph: graph,
            siteDirectory: { _ in sourceDirectory }
        )

        let navigator = SiteNavigatorModel(graph: graph)
        navigator.start(
            site: CurrentSite(id: "site-a", packageURL: root.appendingPathComponent("Test.anglesite"),
                               sourceDirectory: sourceDirectory)
        )
        let result = await workflow.createPost(siteID: "site-a", title: "Stream-Only Post", collection: nil, slug: nil)
        guard case .created = result else {
            Issue.record("expected .created, got \(result)")
            return
        }

        // No `refreshNow()` here — only the long-running `changeStream()` consumer task started by
        // `start()`. Poll with a deadline rather than a single `Task.yield()`: the consumer is a
        // real suspended `Task`, so it needs the runloop to actually schedule it.
        let deadline = Date().addingTimeInterval(2)
        while !flatten(navigator.nodes).contains(where: { $0.title == "Stream-Only Post" }) && Date() < deadline {
            await Task.yield()
        }

        #expect(flatten(navigator.nodes).contains { $0.title == "Stream-Only Post" })
    }
}
