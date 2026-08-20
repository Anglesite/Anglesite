import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PageModelClientTests {
    @Test func fetchDecodesSuccessfulResult() async throws {
        let json = """
        {"version":"sha256:x","path":"src/pages/index.astro","tree":{"id":"n0","kind":"fragment","tag":null,"attrs":[],"span":[0,1],"loc":null,"children":[]}}
        """
        let client = PageModelClient { name, args in
            #expect(name == "get_page_model")
            #expect(args == .object(["path": .string("src/pages/index.astro")]))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: json)], isError: false)
        }
        let model = try await client.fetch(path: "src/pages/index.astro")
        #expect(model.version == "sha256:x")
        #expect(model.tree.id == "n0")
    }

    @Test func fetchThrowsToolFailedOnErrorResult() async throws {
        let client = PageModelClient { _, _ in
            MCPClient.ToolCallResult(
                content: [.init(type: "text", text: #"{"type":"anglesite:page-model-failed","reason":"read-failed","detail":"nope"}"#)],
                isError: true)
        }
        await #expect(throws: PageModelClient.ModelError.toolFailed(reason: "read-failed", detail: "nope")) {
            _ = try await client.fetch(path: "src/pages/missing.astro")
        }
    }

    @Test func fetchThrowsNotConnectedWhenNoClient() async throws {
        let client = PageModelClient(mcpClient: { nil })
        await #expect(throws: PageModelClient.ModelError.notConnected) {
            _ = try await client.fetch(path: "src/pages/index.astro")
        }
    }

    /// These strings are owner-facing HUD text on the click-to-place failure path, so they have to
    /// read like the rest of the app: "sidecar", not "plugin", and a sentence a person can act on
    /// rather than a raw validator message (#768 final review, Finding 10).
    @Test func friendlyMessagesAreWrittenForOwnersNotForTheWire() {
        let decodeFailed = PageModelClient.ModelError.decodeFailed("keyNotFound(...)").friendlyMessage
        #expect(decodeFailed.contains("sidecar"))
        #expect(!decodeFailed.lowercased().contains("plugin"))

        let invalidInput = PageModelClient.ModelError
            .toolFailed(reason: "invalid-input", detail: "not a project-relative .astro path: /").friendlyMessage
        #expect(invalidInput.hasPrefix("Couldn't place the effect here"))
    }
}
