import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// A manually-released stand-in for `ComponentEditorModel`'s `ColorPicker` debounce timer
/// (its `Sleep` seam), in the mold of `InvisiblePublishQueueTests.ManualDebounceGate`: each
/// `debounceColorCommit` parks here instead of racing a real 350 ms `Task.sleep` against the
/// test's own wall-clock waits. Under concurrent-agent load on one Mac that race left the
/// timer still pending when the "settled" assertion ran (#1721), even though the test passes
/// in isolation — the same class of flake #762 fixed for the publish queue.
///
/// Unlike the publish-queue gate, this one models cancellation: a timer the model cancels
/// (a superseding `debounceColorCommit`, or `removeDeclaration`) is torn down at once and
/// counted in `cancelledCount()`, so a test asserts cancellation directly rather than by
/// waiting a window out and checking nothing happened.
private actor ManualDebounceGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled = 0

    /// Parks until `release()` — or throws `CancellationError` as soon as the calling task is
    /// cancelled, exactly as the real `Task.sleep` would.
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await park(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func park(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = continuation
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        cancelled += 1
        continuation.resume(throwing: CancellationError())
    }

    /// Timers currently parked (armed and not yet released or cancelled).
    func armedCount() -> Int { waiters.count }

    /// Timers torn down by task cancellation since the gate was created.
    func cancelledCount() -> Int { cancelled }

    /// "Elapses" every armed timer at once.
    func release() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Coverage for the draft/dirty/commit/debounce state #824 moved out of `ComponentEditorView`
/// and onto `ComponentEditorModel` — none of this needs a live view to exercise.
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

    /// Polls `condition` until it holds or `timeout` elapses. The deadline is deliberately
    /// generous: it only bounds how long a genuine failure hangs, while a passing test returns
    /// as soon as the condition holds (same shape as `InvisiblePublishQueueTests.waitUntil`).
    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("timed out waiting for debounce state")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        model.commitSelector(rule: wrapRule)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(router.messages.isEmpty)
    }

    @Test("commitSelector sends setRuleSelector when the draft differs")
    func commitSelectorSendsWhenChanged() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setSelectorDraft(".wrap-renamed", for: wrapRule)
        model.commitSelector(rule: wrapRule)
        try? await Task.sleep(for: .milliseconds(30))
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
    func removeDeclarationClearsDraftsAndCancelsDebounce() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })
        model.setValueDraft("2rem", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        await waitUntil { await gate.armedCount() == 1 }

        model.removeDeclaration(rule: wrapRule, decl: paddingDecl)
        // The draft is gone immediately (falls back to the model's own value)...
        #expect(model.valueDraft(for: paddingDecl) == "1rem")
        // ...and the pending timer is torn down rather than left to fire after the remove, so
        // the only message the router ever sees is the remove itself.
        await waitUntil { await gate.cancelledCount() == 1 }
        #expect(await gate.armedCount() == 0)
        await waitUntil { router.messages.count == 1 }
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.removeStyleProperty)
    }

    // MARK: - ColorPicker debounce

    @Test("debounceColorCommit commits the settled value after the debounce window and calls onSettled")
    func debounceColorCommitSettles() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })
        model.setValueDraft("#112233", for: paddingDecl)

        var settled = false
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl) { settled = true }

        // Parked on the timer: nothing has been written and the settle callback hasn't run.
        await waitUntil { await gate.armedCount() == 1 }
        #expect(router.messages.isEmpty)
        #expect(!settled)

        // Elapse the window; the commit lands and `onSettled` follows it.
        await gate.release()
        await waitUntil { settled }
        #expect(router.messages.count == 1)
        guard case .object(let obj)? = router.messages.first?.component else {
            Issue.record("expected object payload")
            return
        }
        #expect(obj["value"] == .string("#112233"))
        #expect(settled)
    }

    @Test("a second debounceColorCommit call cancels the first pending commit")
    func debounceColorCommitCancelsPrevious() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let gate = ManualDebounceGate()
        let model = await makeLoadedModel(router: router, sleep: { _ in try await gate.sleep() })

        model.setValueDraft("#111111", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)
        await waitUntil { await gate.armedCount() == 1 }
        model.setValueDraft("#222222", for: paddingDecl)
        model.debounceColorCommit(ruleIndex: 0, rule: wrapRule, decl: paddingDecl)

        // The first timer is torn down and the second armed in its place.
        await waitUntil {
            let cancelled = await gate.cancelledCount()
            let armed = await gate.armedCount()
            return cancelled == 1 && armed == 1
        }
        await gate.release()
        await waitUntil { !router.messages.isEmpty }
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
        model.commitAttr(node: sectionNode, name: "class") // no draft at all
        try? await Task.sleep(for: .milliseconds(30))
        #expect(router.messages.isEmpty)

        model.setAttrValueDraft("wrap", node: sectionNode, name: "class") // same as current
        model.commitAttr(node: sectionNode, name: "class")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(router.messages.isEmpty)
    }

    @Test("commitAttr sends setAttr when the draft differs from the current value")
    func commitAttrSendsWhenChanged() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setAttrValueDraft("wrap wide", node: sectionNode, name: "class")
        model.commitAttr(node: sectionNode, name: "class")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(router.messages.count == 1)
        #expect(router.messages.first?.op == EditMessage.Op.setAttr)
    }

    @Test("removeAttr discards any pending draft before removing")
    func removeAttrDiscardsDraft() async {
        let router = ScriptedRouter(replies: [EditReply(id: "x", status: .applied, message: nil)])
        let model = await makeLoadedModel(router: router)
        model.setAttrValueDraft("typed but never submitted", node: sectionNode, name: "class")
        model.removeAttr(node: sectionNode, name: "class")
        try? await Task.sleep(for: .milliseconds(30))
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
