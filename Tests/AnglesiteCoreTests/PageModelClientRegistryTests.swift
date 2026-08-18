import Testing
@testable import AnglesiteCore

/// Covers `PageModelClientRegistry`'s acceptance criteria: register / unregister / lookup, plus
/// the last-writer-wins overwrite — the `get_page_model` counterpart to
/// `EditRouterRegistryTests`. Tests use a private actor instance (not `.shared`) so they don't
/// bleed across the suite.
struct PageModelClientRegistryTests {
    /// Builds a `PageModelClient` whose `fetch(path:)` always returns a one-node model tagged
    /// with `label`, so a test can tell which registered client actually answered.
    private func stubClient(_ label: String) -> PageModelClient {
        PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let text = """
            {"version":"v1","path":"/","tree":{"id":"n1","kind":"element","tag":"\(label)","attrs":[],"span":[0,0],"children":[]}}
            """
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: text)], isError: false)
        })
    }

    @Test("Lookup returns nil for an unregistered siteID")
    func lookup_returnsNilForUnknown() async {
        let registry = PageModelClientRegistry()
        let client = await registry.pageModelClient(for: "missing")
        #expect(client == nil)
    }

    @Test("Register then lookup returns the same client")
    func register_lookup_roundTrips() async throws {
        let registry = PageModelClientRegistry()
        await registry.register(stubClient("a"), for: "s1")
        let found = await registry.pageModelClient(for: "s1")
        let model = try await found?.fetch(path: "/")
        #expect(model?.tree.tag == "a")
    }

    @Test("Last writer wins on duplicate siteID")
    func register_lastWriterWins() async throws {
        let registry = PageModelClientRegistry()
        await registry.register(stubClient("first"), for: "s1")
        await registry.register(stubClient("second"), for: "s1")
        let found = await registry.pageModelClient(for: "s1")
        let model = try await found?.fetch(path: "/")
        #expect(model?.tree.tag == "second")
    }

    @Test("Unregister removes the client")
    func unregister_removes() async {
        let registry = PageModelClientRegistry()
        await registry.register(stubClient("a"), for: "s1")
        await registry.unregister(siteID: "s1")
        let found = await registry.pageModelClient(for: "s1")
        #expect(found == nil)
    }

    @Test("Unregistering an unknown siteID is a silent no-op")
    func unregister_unknown_silent() async {
        let registry = PageModelClientRegistry()
        await registry.unregister(siteID: "missing")
        // No throw, no crash; the registry is just still empty.
        #expect(await registry.knownSiteIDs().isEmpty)
    }

    @Test("knownSiteIDs reflects current registrations across sites")
    func knownSiteIDs_reflectsRegistrations() async {
        let registry = PageModelClientRegistry()
        await registry.register(stubClient("a"), for: "s1")
        await registry.register(stubClient("b"), for: "s2")
        await registry.register(stubClient("c"), for: "s3")
        await registry.unregister(siteID: "s2")
        #expect(await registry.knownSiteIDs() == ["s1", "s3"])
    }
}
