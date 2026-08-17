// Tests/AnglesiteCoreTests/PageModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PageModelTests {
    @Test func decodesSidecarWireShape() throws {
        let json = """
        {
          "version": "sha256:abc",
          "path": "src/pages/index.astro",
          "tree": {
            "id": "n0", "kind": "fragment", "tag": null, "attrs": [], "span": [0, 100], "loc": null,
            "children": [
              {
                "id": "n1", "kind": "element", "tag": "section", "attrs": [{"name": "class", "value": "hero"}],
                "span": [0, 50], "loc": {"line": 1, "column": 1},
                "children": [
                  {"id": "n2", "kind": "text", "tag": null, "attrs": [], "span": [5, 10], "loc": null, "children": [], "text": "hi"}
                ]
              },
              {
                "id": "n3", "kind": "component", "tag": "Hcard", "attrs": [],
                "span": [50, 80], "loc": {"line": 5, "column": 1}, "children": [],
                "block": {"manifestPath": "src/components/Hcard.astro", "name": "Business Card", "description": "d", "icon": null, "propEditors": [], "slots": []}
              }
            ]
          }
        }
        """
        let model = try JSONDecoder().decode(PageModel.self, from: Data(json.utf8))
        #expect(model.version == "sha256:abc")
        #expect(model.tree.kind == .fragment)
        #expect(model.tree.children.count == 2)
        #expect(model.tree.children[0].tag == "section")
        #expect(model.tree.children[0].attrs.first?.value == "hero")
        #expect(model.tree.children[0].children.first?.text == "hi")
        #expect(model.tree.children[1].block?.name == "Business Card")
        #expect(model.tree.children[1].span.start == 50)
    }
}
