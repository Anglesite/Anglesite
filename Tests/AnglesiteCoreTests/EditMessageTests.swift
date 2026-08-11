import Testing
@testable import AnglesiteCore

struct EditMessageTests {
    /// Matches the `ElementInfo` shape the JS overlay sends — the plugin's `server/selector.mjs`
    /// resolves it server-side to a final CSS selector. See #18.
    private func validSelector() -> [String: Any] {
        [
            "tag": "P",
            "classes": [] as [String],
            "nthChild": 2,
            "ancestors": [] as [Any],
        ]
    }

    private func validBody(overrides: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "id": "edit-1",
            "type": "anglesite:apply-edit",
            "path": "/about/",
            "selector": validSelector(),
            "op": "replace-text",
            "value": "Hello, world.",
        ]
        for (k, v) in overrides { body[k] = v }
        return body
    }

    @Test("Decodes valid apply-edit message") func decodesValidApplyEditMessage() {
        let result = EditMessage.decode(from: validBody())
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg.id == "edit-1")
        #expect(msg.type == .applyEdit)
        #expect(msg.path == "/about/")
        // The selector is forwarded structurally to the plugin; check a couple of fields here.
        guard case .object(let dict) = msg.selector else {
            Issue.record("expected .object selector, got \(msg.selector)")
            return
        }
        #expect(dict["tag"] == .string("P"))
        #expect(dict["nthChild"] == .int(2))
        #expect(msg.op == "replace-text")
        #expect(msg.value == .string("Hello, world."))
    }

    @Test("Decodes when value is absent") func decodesWhenValueIsAbsent() {
        var body = validBody()
        body.removeValue(forKey: "value")
        let result = EditMessage.decode(from: body)
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg.value == nil)
    }

    @Test("Decodes object value") func decodesObjectValue() {
        let result = EditMessage.decode(from: validBody(overrides: ["value": ["a": 1, "b": "two"] as [String: Any]]))
        guard case .success(let msg) = result else {
            Issue.record("expected success")
            return
        }
        #expect(msg.value == .object(["a": .int(1), "b": .string("two")]))
    }

    @Test("Rejects non-object body") func rejectsNonObjectBody() {
        #expect(EditMessage.decode(from: "just a string") == .failure(.notAnObject))
        #expect(EditMessage.decode(from: 42) == .failure(.notAnObject))
        #expect(EditMessage.decode(from: [1, 2, 3]) == .failure(.notAnObject))
    }

    @Test("Rejects missing required field") func rejectsMissingRequiredField() {
        // "selector" is intentionally excluded: it's optional now (Component Editor ops carry
        // `component` instead) — see `legacyMessageStillDecodes` / `componentMessageEncoding`.
        for missing in ["id", "type", "path", "op"] {
            var body = validBody()
            body.removeValue(forKey: missing)
            #expect(
                EditMessage.decode(from: body) == .failure(.missingField(missing)),
                "expected .missingField(\(missing))"
            )
        }
    }

    @Test("Rejects wrong type on required field") func rejectsWrongTypeOnRequiredField() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["id": 123])) == .failure(.wrongType(field: "id", expected: "string"))
        )
        #expect(
            EditMessage.decode(from: validBody(overrides: ["path": 123])) == .failure(.wrongType(field: "path", expected: "string"))
        )
    }

    @Test("Rejects selector that is not an object") func rejectsSelectorThatIsNotAnObject() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["selector": "p:nth-of-type(2)"])) == .failure(.wrongType(field: "selector", expected: "object"))
        )
        #expect(
            EditMessage.decode(from: validBody(overrides: ["selector": 123])) == .failure(.wrongType(field: "selector", expected: "object"))
        )
    }

    @Test("Rejects unknown message type") func rejectsUnknownMessageType() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["type": "anglesite:something-else"])) == .failure(.unknownType("anglesite:something-else"))
        )
    }

    @Test("New component-style op constants exist")
    func componentStyleOpConstants() {
        #expect(EditMessage.Op.setStyleProperty == "set-style-property")
        #expect(EditMessage.Op.removeStyleProperty == "remove-style-property")
        #expect(EditMessage.Op.addStyleRule == "add-style-rule")
        #expect(EditMessage.Op.setRuleSelector == "set-rule-selector")
    }

    @Test("New component-structure op constants match the plugin's op names")
    func componentStructureOpConstants() {
        #expect(EditMessage.Op.insertNode == "insert-node")
        #expect(EditMessage.Op.moveNode == "move-node")
        #expect(EditMessage.Op.removeNode == "remove-node")
        #expect(EditMessage.Op.setAttr == "set-attr")
    }

    @Test("A component-style message encodes component and omits selector")
    func componentMessageEncoding() {
        let message = EditMessage(
            id: "1",
            path: "src/components/Card.astro",
            selector: nil,
            op: EditMessage.Op.setStyleProperty,
            component: .object([
                "path": .string("src/components/Card.astro"),
                "baseVersion": .string("sha256:abc123456789"),
                "ruleSpan": .array([.int(10), .int(40)]),
                "property": .string("color"),
                "value": .string("red"),
            ]),
            value: nil
        )
        let wire = message.jsonValue
        guard case .object(let dict) = wire else { Issue.record("expected object"); return }
        #expect(dict["selector"] == nil)
        #expect(dict["component"] != nil)
    }

    @Test("A legacy replace-attr message still decodes with selector and no component")
    func legacyMessageStillDecodes() {
        let body: [String: Any] = [
            "id": "1", "type": "anglesite:apply-edit", "path": "/about/",
            "selector": ["tag": "h1", "classes": [], "nthChild": 1],
            "op": "replace-attr", "value": ["name": "class", "value": "big"],
        ]
        switch EditMessage.decode(from: body) {
        case .success(let message):
            #expect(message.component == nil)
        case .failure(let error):
            Issue.record("expected decode success, got \(error)")
        }
    }

    @Test("Op.insertImage matches the sidecar's wire string") func opInsertImageMatchesWireString() {
        #expect(EditMessage.Op.insertImage == "insert-image")
    }

    @Test("Decodes a valid insert-image message with no selector") func decodesInsertImageWithoutSelector() {
        let body: [String: Any] = [
            "id": "edit-2",
            "type": "anglesite:apply-edit",
            "path": "/",
            "op": "insert-image",
            "value": ["filename": "photo.jpg", "mimeType": "image/jpeg", "dataURL": "data:image/jpeg;base64,AA=="],
        ]
        let result = EditMessage.decode(from: body)
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg.op == "insert-image")
        #expect(msg.selector == nil)
    }
}
