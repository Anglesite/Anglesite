import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Streams fixed chunks, or the received prompt itself when `echoPrompt` is set (so tests can
/// assert the model grounded the request in the selected node without a stateful spy).
private struct FakeExplainer: SiteGraphNodeExplaining {
    var chunks: [String] = []
    var echoPrompt = false

    func explain(prompt: String, siteID: String, siteDirectory: URL) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if echoPrompt {
                continuation.yield(prompt)
            } else {
                for chunk in chunks { continuation.yield(chunk) }
            }
            continuation.finish()
        }
    }
}

private struct ThrowingExplainer: SiteGraphNodeExplaining {
    let error: any Error

    func explain(prompt: String, siteID: String, siteDirectory: URL) async throws -> AsyncThrowingStream<String, Error> {
        throw error
    }
}

/// `.timeLimit`: see #1349 — the full `AnglesiteAppTests` target has hung indefinitely under
/// local machine contention (many concurrent `swift test` runs oversubscribing the cooperative
/// thread pool), with this suite one of the observed stall points. A wedged test now fails as an
/// unambiguous time-limit violation instead of hanging the whole run forever.
@Suite("SiteGraphExplorerModel explain (#614)", .timeLimit(.minutes(1)))
@MainActor
struct SiteGraphExplorerModelExplainTests {
    /// A started model with one page node loaded and selected.
    private func makeModel(explainer: (any SiteGraphNodeExplaining)?) async throws -> (SiteGraphExplorerModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteGraphExplorerModel(graph: graph, explainer: explainer)
        model.start(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))
        while model.snapshot.nodes.isEmpty { await Task.yield() }
        model.selectedNodeID = model.snapshot.nodes.first?.id
        return (model, root)
    }

    @Test("canExplain requires both a backend and a selection")
    func canExplainGating() async throws {
        let (noBackend, root1) = try await makeModel(explainer: nil)
        defer { try? FileManager.default.removeItem(at: root1) }
        #expect(noBackend.canExplain == false)

        let (model, root2) = try await makeModel(explainer: FakeExplainer())
        defer { try? FileManager.default.removeItem(at: root2) }
        #expect(model.canExplain == true)
        model.selectedNodeID = nil
        #expect(model.canExplain == false)
    }

    @Test("a successful stream accumulates chunks and ends in .complete")
    func successAccumulates() async throws {
        let (model, root) = try await makeModel(explainer: FakeExplainer(chunks: ["This page ", "is the About page."]))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        #expect(model.explainState == .complete("This page is the About page."))
    }

    @Test("the request is grounded in the selected node's facts")
    func promptIsGrounded() async throws {
        let (model, root) = try await makeModel(explainer: FakeExplainer(echoPrompt: true))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        guard case .complete(let echoed) = model.explainState else {
            Issue.record("expected .complete, got \(model.explainState)")
            return
        }
        #expect(echoed.contains("About"))
        #expect(echoed.contains("Do not invent"))
    }

    @Test("AssistantError.unavailable becomes the .unavailable state, not .failed")
    func unavailableState() async throws {
        let (model, root) = try await makeModel(
            explainer: ThrowingExplainer(error: AssistantError.unavailable("Enable Apple Intelligence.")))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        #expect(model.explainState == .unavailable("Enable Apple Intelligence."))
    }

    @Test("any other error becomes .failed")
    func failedState() async throws {
        struct BoomError: Error {}
        let (model, root) = try await makeModel(explainer: ThrowingExplainer(error: BoomError()))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        guard case .failed = model.explainState else {
            Issue.record("expected .failed, got \(model.explainState)")
            return
        }
    }

    @Test("a graph refresh resets the explanation — its grounding snapshot is gone")
    func refreshResets() async throws {
        let (model, root) = try await makeModel(explainer: FakeExplainer(chunks: ["done"]))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        #expect(model.explainState == .complete("done"))
        await model.refreshNow()
        #expect(model.explainState == .idle)
    }

    @Test("stop() winds down an explanation along with the rest of the model")
    func stopResets() async throws {
        let (model, root) = try await makeModel(explainer: FakeExplainer(chunks: ["done"]))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        #expect(model.explainState == .complete("done"))
        model.stop()
        #expect(model.explainState == .idle)
    }

    @Test("changing the selection resets the explanation to .idle")
    func selectionChangeResets() async throws {
        let (model, root) = try await makeModel(explainer: FakeExplainer(chunks: ["done"]))
        defer { try? FileManager.default.removeItem(at: root) }
        model.explainSelectedNode()
        await model.explainTaskForTesting?.value
        #expect(model.explainState == .complete("done"))
        model.selectedNodeID = nil
        #expect(model.explainState == .idle)
    }
}
