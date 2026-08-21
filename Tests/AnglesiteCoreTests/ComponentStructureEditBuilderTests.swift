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

@Suite("ComponentStructureEditBuilder — WYSIWYG ops")
struct ComponentStructureEditBuilderWYSIWYGTests {
    @Test func moveBlockBuildsWireShape() {
        let message = ComponentStructureEditBuilder.moveBlock(
            id: "req-1", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            nodeId: "n5", newParentId: "n2", newIndex: 0)
        #expect(message.op == "moveBlock")
        #expect(message.path == "src/pages/index.astro")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component["newParentId"] == .string("n2"))
        #expect(component["newIndex"] == .int(0))
        #expect(component["baseVersion"] == .string("sha256:abc123def456"))
    }

    @Test func deleteBlockBuildsWireShape() {
        let message = ComponentStructureEditBuilder.deleteBlock(
            id: "req-2", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456", nodeId: "n5")
        #expect(message.op == "deleteBlock")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component.count == 3) // path, baseVersion, nodeId — no extras
    }

    @Test func editTextBuildsWireShape() {
        let runs = [RichTextRun(kind: .text, text: "Hi ", href: nil), RichTextRun(kind: .strong, text: "there", href: nil)]
        let message = ComponentStructureEditBuilder.editText(
            id: "req-3", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            textNodeId: "n5", runs: runs)
        #expect(message.op == "editText")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["textNodeId"] == .string("n5"))
        guard case .array(let wireRuns)? = component["runs"] else {
            Issue.record("expected runs array"); return
        }
        #expect(wireRuns.count == 2)
    }

    // Finding 2 (Critical): the sidecar's actual `editText` schema (apply-edit-schema.mjs's
    // `runs` field, consumed by text-run-edit.mjs's `serializeRuns`) is `{text, marks: string[],
    // href?}` — NOT `RichTextRun`'s own `{kind, text, href, children}` Codable shape. Encoding via
    // `RichTextRun`'s own Codable conformance means Zod silently strips the unrecognized `kind`
    // key and every `editText` op loses its formatting. Each `RichTextRun.Kind` case must map to
    // the correct `marks` array, and `href` must appear on the wire only for `.link`.
    @Test func editTextRunsEncodeMarksMatchingSidecarSchema() {
        let runs: [RichTextRun] = [
            RichTextRun(kind: .text, text: "plain"),
            RichTextRun(kind: .strong, text: "bold"),
            RichTextRun(kind: .em, text: "italic"),
            RichTextRun(kind: .code, text: "code"),
            RichTextRun(kind: .link, text: "click", href: "https://example.com"),
        ]
        let message = ComponentStructureEditBuilder.editText(
            id: "req-3b", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            textNodeId: "n5", runs: runs)
        guard case .object(let component)? = message.component, case .array(let wireRuns)? = component["runs"] else {
            Issue.record("expected component.runs array"); return
        }
        #expect(wireRuns.count == 5)

        func marks(_ i: Int) -> [JSONValue]? {
            guard case .object(let run) = wireRuns[i], case .array(let m)? = run["marks"] else { return nil }
            return m
        }
        func href(_ i: Int) -> JSONValue? {
            guard case .object(let run) = wireRuns[i] else { return nil }
            return run["href"]
        }

        #expect(marks(0) == [])
        #expect(href(0) == nil)

        #expect(marks(1) == [.string("strong")])
        #expect(marks(2) == [.string("em")])
        #expect(marks(3) == [.string("code")])

        // `.link` carries no mark of its own — the wire distinguishes it purely by `href`.
        #expect(marks(4) == [])
        #expect(href(4) == .string("https://example.com"))

        // No non-link run should ever carry an `href` key.
        for i in 0..<3 {
            #expect(href(i) == nil)
        }

        guard case .object(let run0) = wireRuns[0] else { Issue.record("expected object"); return }
        #expect(run0["text"] == .string("plain"))
    }

    @Test func setDesignTokenBuildsWireShape() {
        let message = ComponentStructureEditBuilder.setDesignToken(
            id: "req-4", path: "src/styles/global.css", baseVersion: "sha256:abc123def456",
            token: "--color-primary", tokenValue: "#111111")
        #expect(message.op == "setDesignToken")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        #expect(component["token"] == JSONValue.string("--color-primary"))
        #expect(component["tokenValue"] == JSONValue.string("#111111"))
    }

    @Test func insertBlockNodeBuildsWireShapeForRawMarkup() {
        let message = ComponentStructureEditBuilder.insertBlockNode(
            id: "req-5", path: "src/pages/index.astro", baseVersion: "sha256:abc123def456",
            parentId: "n2", index: 1, node: .raw(markup: "<p id=\"gone\">b</p>"))
        #expect(message.op == "insertBlock")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object"); return
        }
        guard case .object(let node)? = component["node"] else {
            Issue.record("expected node object"); return
        }
        #expect(node["kind"] == JSONValue.string("raw"))
        #expect(node["markup"] == JSONValue.string("<p id=\"gone\">b</p>"))
    }
}
