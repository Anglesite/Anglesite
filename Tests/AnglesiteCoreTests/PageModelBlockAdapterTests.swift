import Testing
@testable import AnglesiteCore

@Suite("PageModelBlockAdapter")
struct PageModelBlockAdapterTests {
    @Test func adaptsFlatTreeWithOneBlock() {
        let pageModel = PageModel(
            version: "sha256:abc123def456",
            path: "src/pages/index.astro",
            tree: .init(
                id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 100), loc: nil, text: nil,
                children: [
                    .init(
                        id: "n1", kind: .element, tag: "main", attrs: [], span: .init(start: 10, end: 90), loc: nil, text: nil,
                        children: [
                            .init(
                                id: "n2", kind: .component, tag: "Hcard", attrs: [.init(name: "name", value: "Ada")],
                                span: .init(start: 20, end: 80), loc: nil, text: nil, children: [],
                                block: .init(manifestPath: "src/components/Hcard.astro", name: "H-Card", description: "", icon: nil, slots: [])),
                        ],
                        block: nil),
                ],
                block: nil))

        let model = PageModelBlockAdapter.adapt(pageModel)

        #expect(model.path == "src/pages/index.astro")
        #expect(model.version == "sha256:abc123def456")
        #expect(model.rootIds == ["n1"])
        #expect(model.blocks.count == 3) // n0, n1, n2 all present — every node, not just blocks

        let main = try! #require(model.blocks["n1"])
        #expect(main.kind == .element)
        #expect(main.slots["default"] == ["n2"])

        let hcard = try! #require(model.blocks["n2"])
        #expect(hcard.kind == .astro)
        #expect(hcard.componentName == "Hcard")
        #expect(hcard.props["name"] == .string("Ada"))
        #expect(hcard.sourceSpan == [20, 80])
    }

    @Test func adaptsNonComponentNodeToElementKind() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 10), loc: nil, text: nil, children: [], block: nil))
        let model = PageModelBlockAdapter.adapt(pageModel)
        let root = try! #require(model.blocks["n0"])
        #expect(root.kind == .fragment)
    }

    @Test func missingSpanBoundsDefaultToZero() {
        let pageModel = PageModel(
            version: "sha256:abc", path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [], block: nil))
        let model = PageModelBlockAdapter.adapt(pageModel)
        #expect(model.blocks["n0"]?.sourceSpan == [0, 0])
    }
}
