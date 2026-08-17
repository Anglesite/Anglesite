import Testing
@testable import AnglesiteCore

@Suite struct ComponentStructureEditBuilderTests {
    @Test("insertNode carries parentId, index, and node spec")
    func insertNodeShape() {
        let message = ComponentStructureEditBuilder.insertNode(
            id: "id-1",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc",
            parentId: "n0",
            index: 1,
            node: .element(tag: "p")
        )
        #expect(message.op == EditMessage.Op.insertNode)
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["parentId"] == .string("n0"))
        #expect(obj["index"] == .int(1))
        guard case .object(let node)? = obj["node"] else { Issue.record("expected node object"); return }
        #expect(node["kind"] == .string("element"))
        #expect(node["tag"] == .string("p"))
    }

    @Test("insertNode component spec carries componentPath")
    func insertNodeComponentSpec() {
        let message = ComponentStructureEditBuilder.insertNode(
            id: "id-2",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc",
            parentId: "n0",
            index: 0,
            node: .component(tag: "Badge", componentPath: "src/components/Badge.astro")
        )
        guard case .object(let obj)? = message.component, case .object(let node)? = obj["node"] else {
            Issue.record("expected component node payload"); return
        }
        #expect(node["kind"] == .string("component"))
        #expect(node["componentPath"] == .string("src/components/Badge.astro"))
    }

    @Test("moveNode carries nodeId, newParentId, newIndex")
    func moveNodeShape() {
        let message = ComponentStructureEditBuilder.moveNode(
            id: "id-3", path: "src/components/Card.astro", baseVersion: "sha256:abc",
            nodeId: "n2", newParentId: "n0", newIndex: 1
        )
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["nodeId"] == .string("n2"))
        #expect(obj["newParentId"] == .string("n0"))
        #expect(obj["newIndex"] == .int(1))
    }

    @Test("removeNode carries nodeId")
    func removeNodeShape() {
        let message = ComponentStructureEditBuilder.removeNode(id: "id-4", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n2")
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["nodeId"] == .string("n2"))
    }

    @Test("setAttr with a value sets it")
    func setAttrValue() {
        let message = ComponentStructureEditBuilder.setAttr(id: "id-5", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n1", name: "class", value: "big")
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["name"] == .string("class"))
        #expect(obj["value"] == .string("big"))
    }

    @Test("setAttr with nil value encodes explicit null (removal)")
    func setAttrRemoval() {
        let message = ComponentStructureEditBuilder.setAttr(id: "id-6", path: "src/components/Card.astro", baseVersion: "sha256:abc", nodeId: "n1", name: "class", value: nil)
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["value"] == .null)
    }

    @Test("extractComponent carries nodeId and a bare newName")
    func extractComponentShape() {
        let message = ComponentStructureEditBuilder.extractComponent(
            id: "id-7",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc",
            nodeId: "n3",
            newName: "Hero"
        )
        #expect(message.op == EditMessage.Op.extractComponent)
        guard case .object(let obj)? = message.component else { Issue.record("expected object component payload"); return }
        #expect(obj["path"] == .string("src/components/Card.astro"))
        #expect(obj["baseVersion"] == .string("sha256:abc"))
        #expect(obj["nodeId"] == .string("n3"))
        // Bare PascalCase identifier — no path prefix, no `.astro` suffix (the server derives the
        // full path), and no leftover `newComponentPath` key.
        #expect(obj["newName"] == .string("Hero"))
        #expect(obj["newComponentPath"] == nil)
    }

    @Test func buildsInsertBlockMessage() {
        let message = ComponentStructureEditBuilder.insertBlock(
            id: "e1", path: "src/pages/index.astro", baseVersion: "sha256:x",
            parentId: "n1", index: 2, manifestBlock: "Particle Field")
        #expect(message.op == "insertBlock")
        #expect(message.path == "src/pages/index.astro")
        #expect(message.selector == nil)
        guard case .object(let component)? = message.component else {
            Issue.record("expected object component payload")
            return
        }
        #expect(component["path"] == .string("src/pages/index.astro"))
        #expect(component["baseVersion"] == .string("sha256:x"))
        #expect(component["parentId"] == .string("n1"))
        #expect(component["index"] == .int(2))
        #expect(component["manifestBlock"] == .string("Particle Field"))
        #expect(component["node"] == nil)
    }
}
