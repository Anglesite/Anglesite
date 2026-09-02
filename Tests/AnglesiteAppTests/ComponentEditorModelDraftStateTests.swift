import Testing
import Foundation
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

/// Coverage for the draft/dirty/commit/debounce state #824 moved out of `ComponentEditorView`
/// and onto `ComponentEditorModel` — none of this needs a live view to exercise.
///
/// Nothing here sleeps for a guessed interval (#1721): the `ColorPicker` debounce tests drive
/// the model's `Sleep` seam with the shared `ManualDebounceGate`, and every fire-and-forget
/// write (`commitSelector`, `commitAttr`, `removeAttr`, `removeDeclaration`) is awaited via the
/// `Task` it returns — so a no-op is proven synchronously (`nil`) and a real write is asserted
/// only once it has landed, however loaded the Mac is.
@Suite("ComponentEditorModel draft state (#824)")
@MainActor
struct ComponentEditorModelDraftStateTests {
    /// A fixed `.astro` component model used across these tests: a `section` (n1) containing a
    /// `p` (n2, styled by `.wrap`) and a `span` (n3), a sibling `aside` (n4), and a sealed
    /// `Badge` component instance (n5) — enough structure for both draft-state and drag/drop
    /// coverage without leaning on the shared `ComponentModelTests.fixture` (whose ids/shape are
    /// tuned for outline-only tests).
    static let fixtureJSON = """
    {
      "version": "v1",
      "path": "src/components/Card.astro",
      "template": {
        "id": "n0", "kind": "fragment", "tag": null, "attrs": [], "span": [0, 200], "loc": null,
        "children": [
          {
            "id": "n1", "kind": "element", "tag": "section",
            "attrs": [{"name": "class", "value": "wrap"}],
            "span": [10, 100], "loc": {"line": 3, "column": 1},
            "children": [
              {"id": "n2", "kind": "element", "tag": "p", "attrs": [], "span": [20, 30], "loc": {"line": 5, "column": 10}, "children": []},
              {"id": "n3", "kind": "element", "tag": "span", "attrs": [], "span": [31, 40], "loc": {"line": 6, "column": 3}, "children": []}
            ]
          },
          {"id": "n4", "kind": "element", "tag": "aside", "attrs": [], "span": [101, 110], "loc": {"line": 9, "column": 1}, "children": []},
          {"id": "n5", "kind": "component", "tag": "Badge", "attrs": [], "span": [111, 130], "loc": {"line": 10, "column": 1}, "children": []}
        ]
      },
      "frontmatter": {
        "source": "interface Props { title: string; }",
        "span": [4, 40],
        "props": [{"name": "title", "type": "string", "optional": false, "default": null}]
      },
      "styles": [
        {"selector": ".wrap", "media": null, "span": [150, 175],
         "declarations": [{"property": "padding", "value": "1rem", "span": [158, 172]}]}
      ],
      "clientScript": {"source": "console.log(1)", "span": [180, 195]}
    }
    """

    /// Reply-scripted router: returns replies in order (looping the last one once exhausted) and
    /// records every message it was handed, so a test can inspect not just the last call but the
    /// full sequence (e.g. proving a rename's second write used a freshly re-derived span).
    final class ScriptedRouter: EditRouter {
        var messages: [EditMessage] = []
        private var replies: [EditReply]

        init(replies: [EditReply]) {
            self.replies = replies
        }

        func apply(_ message: EditMessage) async -> EditReply {
            messages.append(message)
            guard !replies.isEmpty else {
                return EditReply(id: message.id, status: .applied, message: nil)
            }
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }

    private func modelClient(json: String = ComponentEditorModelDraftStateTests.fixtureJSON) -> ComponentModelClient {
        ComponentModelClient(toolCaller: { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: json)], isError: false)
        })
    }

    /// Builds a `ComponentEditorModel` backed by `router` and already `load()`ed against
    /// `fixtureJSON`, so `model.model`/`outlineRows` are populated the way a real load would
    /// leave them. `sleep` substitutes the `ColorPicker` debounce timer — the debounce tests
    /// pass a `ManualDebounceGate`; everything else leaves the production default.
    private func makeLoadedModel(
        router: EditRouter,
        json: String = ComponentEditorModelDraftStateTests.fixtureJSON,
        sleep: @escaping ComponentEditorModel.Sleep = { try await Task.sleep(for: $0) }
    ) async -> ComponentEditorModel {
        let context = ComponentEditorContext(
            baseURL: nil,
            modelClient: modelClient(json: json),
            sourceRoot: URL(fileURLWithPath: "/tmp/anglesite-draft-state-tests-\(UUID().uuidString)"),
            editRouter: router
        )
        let file = FileRef(url: URL(fileURLWithPath: "/tmp/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let model = ComponentEditorModel(file: file, context: context, sleep: sleep)
        await model.load()
        return model
    }

    /// `ComponentModel`'s nested types have no public memberwise initializers (by design — they're
    /// meant to come from decoding the plugin's tool JSON), so fixture instances are pulled out of
    /// a decoded `ComponentModel` rather than constructed directly, same as `ComponentOutlineTests`.
    private func fixtureModel() -> ComponentModel {
        try! JSONDecoder().decode(ComponentModel.self, from: Data(ComponentEditorModelDraftStateTests.fixtureJSON.utf8))
    }

    private var wrapRule: ComponentModel.StyleRule {
        fixtureModel().styles[0]
    }

    private var paddingDecl: ComponentModel.Declaration {
        wrapRule.declarations[0]
    }

    // MARK: - Selector drafts

    @Test("selectorDraft falls back to the rule's own selector until edited")
    func selectorDraftFallsBackToModelValue() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        #expect(model.selectorDraft(for: wrapRule) == ".wrap")
        model.setSelectorDraft(".wrap-new", for: wrapRule)
        #expect(model.selectorDraft(for: wrapRule) == ".wrap-new")
    }

    @Test("commitSelector is a no-op when the draft matches the model's current selector")
    func commitSelectorNoOpWhenUnchanged() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        model.setSelectorDraft(".wrap", for: wrapRule) // same as current
        #expect(model.commitSelector(rule: wrapRule) == nil) // no write task was even spawned
        #expect(router.messages.isEmpty)
    }

    @Test("commitSelector sends setRuleSelector when the draft differs")
    func commitSelectorSendsWhenChanged() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setSelectorDraft(".wrap-renamed", for: wrapRule)
        await model.commitSelector(rule: wrapRule)?.value
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.setRuleSelector)
    }

    // MARK: - Declaration drafts

    @Test("commitDeclaration is a no-op when neither the property nor the value changed")
    func commitDeclarationNoOpWhenUnchanged() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        await model.commitDeclaration(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        #expect(router.messages.isEmpty)
    }

    @Test("commitDeclaration sends a plain setStyleProperty when only the value changed")
    func commitDeclarationValueOnlyChange() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setValueDraft("2rem", for: paddingDecl)
        await model.commitDeclaration(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.setStyleProperty)
    }

    @Test("commitDeclaration on a property rename removes then re-adds against a freshly reloaded span")
    func commitDeclarationRenameUsesFreshSpan() async {
        // First reply (the remove) piggybacks a model whose rule span has moved — simulating the
        // byte-offset shift a real remove causes. The second write (the add) must target that
        // fresh span, not the original `wrapRule.span` captured before either write ran.
        let shiftedJSON = ComponentEditorModelDraftStateTests.fixtureJSON
            .replacingOccurrences(of: "\"span\": [150, 175]", with: "\"span\": [140, 160]")
        let shiftedModel = try! JSONDecoder().decode(ComponentModel.self, from: Data(shiftedJSON.utf8))
        let router = ScriptedRouter(replies: [
            EditReply(id: "remove", status: .applied, message: nil, model: shiftedModel),
            EditReply(id: "add", status: .applied, message: nil),
        ])
        let model = await makeLoadedModel(router: router)
        model.setPropertyDraft("padding-inline", for: paddingDecl)
        await model.commitDeclaration(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)

        #expect(router.messages.count == 2)
        #expect(router.messages[0].op == EditMessage.Op.removeStyleProperty)
        #expect(router.messages[1].op == EditMessage.Op.setStyleProperty)
        guard case .object(let removeObj)? = router.messages[0].component,
              case .object(let addObj)? = router.messages[1].component,
              case .array(let removeSpan)? = removeObj["ruleSpan"],
              case .array(let addSpan)? = addObj["ruleSpan"]
        else {
            Issue.record("expected object payloads with ruleSpan arrays")
            return
        }
        #expect(removeSpan == [.int(150), .int(175)]) // the original span, captured before either write
        #expect(addSpan == [.int(140), .int(160)]) // re-derived from the piggybacked post-remove model
    }

    @Test("removeDeclaration clears pending drafts and cancels an in-flight debounce")
    func removeDeclarationClearsDraftsAndCancelsDebounce() async throws {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })
        model.setValueDraft("2rem", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        try await waitUntil("the debounce timer to arm") { await gate.armedCount() == 1 }

        let remove = model.removeDeclaration(rule: wrapRule, decl: paddingDecl)
        // The draft is gone immediately (falls back to the model's own value)...
        #expect(model.valueDraft(for: paddingDecl) == "1rem")
        // ...and the pending timer is torn down rather than left to fire after the remove, so
        // the only message the router ever sees is the remove itself.
        try await waitUntil("the debounce timer to be cancelled") { await gate.cancelledCount() == 1 }
        #expect(await gate.armedCount() == 0)
        await remove.value
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.removeStyleProperty)
    }

    // MARK: - ColorPicker debounce

    @Test("debounceColorCommit commits the settled value after the debounce window and calls onSettled")
    func debounceColorCommitSettles() async throws {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })
        model.setValueDraft("#112233", for: paddingDecl)

        var settled = false
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl) { settled = true }

        // Parked on the timer: nothing has been written and the settle callback hasn't run.
        try await waitUntil("the debounce timer to arm") { await gate.armedCount() == 1 }
        #expect(router.messages.isEmpty)
        #expect(!settled)

        // Elapse the window; the commit lands and `onSettled` follows it.
        await gate.release()
        try await waitUntil("onSettled to run") { settled }
        #expect(router.messages.count == 1)
        guard case .object(let obj)? = router.messages.first?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["value"] == .string("#112233"))
        #expect(settled)
    }

    @Test("a second debounceColorCommit call cancels the first pending commit")
    func debounceColorCommitCancelsPrevious() async throws {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })

        model.setValueDraft("#111111", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        try await waitUntil("the first debounce timer to arm") { await gate.armedCount() == 1 }
        model.setValueDraft("#222222", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)

        // The first timer is torn down and the second armed in its place.
        try await waitUntil("the first timer cancelled and the second armed") {
            let cancelled = await gate.cancelledCount()
            let armed = await gate.armedCount()
            return cancelled == 1 && armed == 1
        }
        await gate.release()
        try await waitUntil("the settled commit to land") { !router.messages.isEmpty }
        // Exactly one commit fires — proof the first was cancelled rather than both landing.
        #expect(router.messages.count == 1)
        guard case .object(let obj)? = router.messages.first?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["value"] == .string("#222222"))
    }

    // MARK: - Attribute drafts

    private var sectionNode: ComponentModel.Node {
        ComponentModel.Node(
            id: "n1", kind: .element, tag: "section",
            attrs: [ComponentModel.Attr(name: "class", value: "wrap")],
            span: .init(start: 10, end: 100), loc: .init(line: 3, column: 1), text: nil, children: []
        )
    }

    @Test("attrValueDraft falls back to the node's current attribute value")
    func attrValueDraftFallsBack() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        #expect(model.attrValueDraft(node: sectionNode, name: "class") == "wrap")
        model.setAttrValueDraft("wrap wide", node: sectionNode, name: "class")
        #expect(model.attrValueDraft(node: sectionNode, name: "class") == "wrap wide")
    }

    @Test("commitAttr is a no-op without a draft, and no-ops when the draft matches the current value")
    func commitAttrNoOps() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        #expect(model.commitAttr(node: sectionNode, name: "class") == nil) // no draft at all
        #expect(router.messages.isEmpty)

        model.setAttrValueDraft("wrap", node: sectionNode, name: "class") // same as current
        #expect(model.commitAttr(node: sectionNode, name: "class") == nil)
        #expect(router.messages.isEmpty)
    }

    @Test("commitAttr sends setAttr when the draft differs from the current value")
    func commitAttrSendsWhenChanged() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setAttrValueDraft("wrap wide", node: sectionNode, name: "class")
        await model.commitAttr(node: sectionNode, name: "class")?.value
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.setAttr)
    }

    @Test("removeAttr discards any pending draft before removing")
    func removeAttrDiscardsDraft() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setAttrValueDraft("typed but never submitted", node: sectionNode, name: "class")
        await model.removeAttr(node: sectionNode, name: "class").value
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.setAttr)
        // The stale draft is gone — a fresh lookup falls back to (the reloaded) model state, not
        // the discarded in-progress text.
        #expect(model.attrValueDraft(node: sectionNode, name: "class") != "typed but never submitted")
    }

    // MARK: - Props form draft

    @Test("propsDraftDirty is false right after load and true once the draft diverges")
    func propsDraftDirtyTracksDivergence() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        #expect(!model.propsDraftDirty)
        model.propsDraft[0].type = "number"
        #expect(model.propsDraftDirty)
    }

    @Test("savePropsDraft drops a blank in-progress row and sends the rest")
    func savePropsDraftDropsBlankRows() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.propsDraft.append(ComponentEditorModel.PropDraft(name: "", type: "string", optional: false, defaultValue: ""))
        let applied = await model.savePropsDraft()
        #expect(applied)
        #expect(router.messages.count == 1)
        guard case .object(let obj)? = router.messages.first?.component, case .array(let props)? = obj["props"] else {
            Issue.record("expected a props array")
            return
        }
        #expect(props.count == 1) // the blank row never made it onto the wire
    }

    // MARK: - Code pane drafts

    @Test("codeDraftDirty compares against the model's current zone source")
    func codeDraftDirtyTracksZoneSource() async {
        let router = ScriptedRouter(replies: [])
        let model = await makeLoadedModel(router: router)
        #expect(!model.codeDraftDirty(zone: .client))
        model.codeDrafts[.client] = "console.log(2)"
        #expect(model.codeDraftDirty(zone: .client))
    }

    @Test("saveCodeDraft sends setScriptZone with the zone's raw value and current draft text")
    func saveCodeDraftSends() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.codeDrafts[.frontmatter] = "interface Props { title: string; count: number; }"
        let applied = await model.saveCodeDraft(zone: .frontmatter)
        #expect(applied)
        guard case .object(let obj)? = router.messages.first?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["zone"] == .string("frontmatter"))
        #expect(obj["source"] == .string("interface Props { title: string; count: number; }"))
    }

    // MARK: - Reconciliation

    /// A `ComponentModelClient` test seam whose returned JSON can change between calls (a plain
    /// `let` fixture string can't model a live version transition on one model instance).
    final class MutableJSONSource: @unchecked Sendable {
        var json: String
        init(_ json: String) { self.json = json }
    }

    @Test("propsDraft/codeDrafts reseed from a genuinely new model version, but survive an unchanged reload")
    func reconciliationOnlyFiresOnVersionChange() async {
        let source = MutableJSONSource(ComponentEditorModelDraftStateTests.fixtureJSON)
        let client = ComponentModelClient(toolCaller: { _, _ in
            MCPClient.ToolCallResult(content: [.init(type: "text", text: source.json)], isError: false)
        })
        let context = ComponentEditorContext(
            baseURL: nil, modelClient: client,
            sourceRoot: URL(fileURLWithPath: "/tmp/anglesite-draft-state-tests-\(UUID().uuidString)"),
            editRouter: ScriptedRouter(replies: [])
        )
        let file = FileRef(url: URL(fileURLWithPath: "/tmp/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let model = ComponentEditorModel(file: file, context: context)
        await model.load()

        // Dirty both drafts without saving.
        model.propsDraft[0].name = "heading"
        model.codeDrafts[.client] = "console.log('dirty')"

        // A reload against the SAME version must leave the in-progress drafts alone — mirrors
        // the old view's `.onChange(of: model?.model?.version)`, which only fires when the
        // version actually differs from the previous one.
        await model.load()
        #expect(model.propsDraft[0].name == "heading")
        #expect(model.codeDrafts[.client] == "console.log('dirty')")

        // A reload against a *different* version reseeds both, discarding the in-progress
        // edits — the documented tradeoff (same as a stale-write "Reload").
        source.json = ComponentEditorModelDraftStateTests.fixtureJSON.replacingOccurrences(of: "\"version\": \"v1\"", with: "\"version\": \"v2\"")
        await model.load()
        #expect(model.propsDraft[0].name == "title") // back to the fixture's own prop name
        #expect(model.codeDrafts[.client] == "console.log(1)") // back to the fixture's script source
    }
}
