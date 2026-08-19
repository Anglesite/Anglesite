import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGOpTranslator")
struct WYSIWYGOpTranslatorTests {
    // NOTE: the plan/brief named this test "...ToRawNodeInsert" and originally asserted
    // node["kind"] == "raw", but that's unreachable: `BlockNodeContent` (kind/componentName/
    // props/slots/sourceSpan/richText) carries no pre-serialized markup, and `nodeSpec(for:)`
    // (as literally specified by the brief) never constructs `.raw(markup:)` — only
    // `.component(...)`/`.element(...)`. Asserting "raw" here is a stale artifact from an
    // earlier design iteration; fixed to assert the actual, implementable-from-available-data
    // behavior. Flagged as a concern in the task report rather than silently reinterpreted.
    @Test func translatesInsertBlockToComponentNodeInsert() {
        let content = BlockNodeContent(
            kind: .astro, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: "n2", slot: "default", index: 1, newId: "n7", block: content)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-1", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "insertBlock")
        guard case .object(let component)? = message.component, case .object(let node)? = component["node"] else {
            Issue.record("expected component.node object"); return
        }
        #expect(node["kind"] == .string("component"))
        #expect(node["tag"] == .string("p"))
        #expect(node["componentPath"] == .string("p"))
    }

    @Test func translatesMoveBlockDroppingSlotNames() {
        let op = Op.moveBlock(blockId: "n5", fromParentId: "n2", fromSlot: "default", fromIndex: 0, toParentId: "n3", toSlot: "default", toIndex: 2)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-2", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "moveBlock")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["nodeId"] == .string("n5"))
        #expect(component["newParentId"] == .string("n3"))
        #expect(component["newIndex"] == .int(2))
        #expect(component["fromSlot"] == nil) // slot names never reach the wire
    }

    @Test func translatesDeleteBlock() {
        let op = Op.deleteBlock(parentId: "n2", slot: "default", index: 0, blockId: "n5", block: BlockNode(id: "n5", kind: .astro, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0]))
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-3", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "deleteBlock")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["nodeId"] == .string("n5"))
    }

    @Test func translatesSetProp() {
        let op = Op.setProp(blockId: "n5", propName: "title", value: .string("New"), previousValue: .string("Old"))
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-4", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "set-attr") // reuses the existing Component Editor resolver
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["name"] == .string("title"))
        #expect(component["value"] == .string("New"))
    }

    @Test func translatesEditText() {
        let op = Op.editText(blockId: "n5", runs: [RichTextRun(kind: .text, text: "hi")], previousRuns: [])
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-5", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.op == "editText")
    }

    @Test func translatesSetDesignTokenAlwaysTargetsGlobalCSS() {
        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-6", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        #expect(message.path == "src/styles/global.css") // NOT the page path passed in
    }

    // `setAttr`'s wire contract treats `value: nil` as "remove the attribute" — an object/array
    // PropValue must never round-trip through `nil` there, or a rich-valued setProp would
    // silently delete the attribute instead of merely failing to translate it richly.
    @Test func translatesSetPropWithObjectValueWithoutDeletingTheAttribute() {
        let op = Op.setProp(blockId: "n5", propName: "config", value: .object(["a": .number(1)]), previousValue: .null)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-7", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["value"] != .null) // must not take the "remove attribute" path
        guard case .string(let json)? = component["value"] else { Issue.record("expected value to encode as a string"); return }
        #expect(json.contains("\"a\""))
    }

    @Test func translatesSetPropWithArrayValueWithoutDeletingTheAttribute() {
        let op = Op.setProp(blockId: "n5", propName: "tags", value: .array([.string("x")]), previousValue: .null)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-8", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["value"] != .null) // must not take the "remove attribute" path
        guard case .string(let json)? = component["value"] else { Issue.record("expected value to encode as a string"); return }
        #expect(json.contains("x"))
    }

    @Test func translatesSetPropWithWholeNumberValueDroppingTrailingZero() {
        let op = Op.setProp(blockId: "n5", propName: "count", value: .number(5), previousValue: .null)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-9", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["value"] == .string("5")) // not "5.0"
    }

    @Test func translatesSetPropWithFractionalNumberValue() {
        let op = Op.setProp(blockId: "n5", propName: "opacity", value: .number(5.5), previousValue: .null)
        let message = WYSIWYGOpTranslator.translate(op, requestId: "req-10", path: "src/pages/index.astro", baseVersion: "sha256:abc")
        guard case .object(let component)? = message.component else { Issue.record("expected component"); return }
        #expect(component["value"] == .string("5.5"))
    }
}
