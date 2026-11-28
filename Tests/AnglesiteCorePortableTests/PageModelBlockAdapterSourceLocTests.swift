import Testing
import Foundation
@testable import AnglesiteCore

/// `PageModelBlockAdapter` carries each node's source position and a manifest component's file
/// into `BlockNode` (#2239), so the engine can find blocks on the live preview. Portable, so it
/// runs on the Linux lane too.
@Suite("PageModelBlockAdapter source positions (#2239)")
struct PageModelBlockAdapterSourceLocTests {
    private func pageModel() -> PageModel {
        let heading = PageModel.Node(
            id: "n1", kind: .element, tag: "h1", attrs: [], span: .init(start: 10, end: 30),
            loc: .init(line: 11, column: 5), text: nil, children: [], block: nil)
        let card = PageModel.Node(
            id: "n2", kind: .component, tag: "TiltCard", attrs: [], span: .init(start: 40, end: 60),
            loc: .init(line: 12, column: 5), text: nil, children: [],
            block: .init(manifestPath: "src/components/effects/TiltCard.astro", name: "Tilt Card",
                         description: "", icon: nil, slots: []))
        let root = PageModel.Node(
            id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 70),
            loc: nil, text: nil, children: [heading, card], block: nil)
        return PageModel(version: "sha256:abc", path: "src/pages/index.astro", tree: root)
    }

    @Test("an element keeps its source position; a fragment without one gets nil")
    func sourceLoc() {
        let model = PageModelBlockAdapter.adapt(pageModel())
        #expect(model.blocks["n1"]?.sourceLoc == PageModel.Loc(line: 11, column: 5))
        #expect(model.blocks["n1"]?.componentPath == nil)
        #expect(model.blocks["n0"]?.sourceLoc == nil)
    }

    @Test("a manifest component carries the file it's defined in")
    func componentPath() {
        let model = PageModelBlockAdapter.adapt(pageModel())
        #expect(model.blocks["n2"]?.componentPath == "src/components/effects/TiltCard.astro")
        #expect(model.blocks["n2"]?.sourceLoc == PageModel.Loc(line: 12, column: 5))
    }

    @Test("encodes the shape the engine reads (types.ts BlockNode), and omits absent fields")
    func encodedShape() throws {
        let model = PageModelBlockAdapter.adapt(pageModel())
        let data = try JSONEncoder().encode(model)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let blocks = try #require(json["blocks"] as? [String: [String: Any]])

        let heading = try #require(blocks["n1"])
        let loc = try #require(heading["sourceLoc"] as? [String: Any])
        #expect(loc["line"] as? Int == 11)
        #expect(loc["column"] as? Int == 5)
        #expect(heading["componentPath"] == nil)

        #expect(blocks["n2"]?["componentPath"] as? String == "src/components/effects/TiltCard.astro")
        #expect(blocks["n0"]?["sourceLoc"] == nil)
    }

    @Test("a model encoded before these fields existed still decodes")
    func decodesOlderModels() throws {
        let json = #"{"id":"n1","kind":"element","componentName":"p","props":{},"slots":{},"sourceSpan":[0,1]}"#
        let node = try JSONDecoder().decode(BlockNode.self, from: Data(json.utf8))
        #expect(node.sourceLoc == nil)
        #expect(node.componentPath == nil)
    }
}
