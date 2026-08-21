import Foundation
import Observation
import WebKit
import AnglesiteCore

/// App-side orchestrator for one mounted WYSIWYG canvas (#1225). Owns the transport and current
/// block selection; menu commands (`FormatCommands`, Edit-menu Duplicate/Delete) and
/// `WYSIWYGUndoCoordinator` talk to this, not to the transport directly.
@MainActor @Observable
final class WYSIWYGCanvasController {
    private(set) var model: BlockModel
    var selectedBlockId: BlockId?
    private let transport: any WYSIWYGHostTransport

    /// True while the canvas holds real AppKit keyboard focus — distinct from `selectedBlockId
    /// != nil`, which persists even after focus moves to the Navigator or an inspector field.
    /// Set by `WYSIWYGCanvasFocusSentinel` (`PreviewView.swift`), the `NSWindow.firstResponder`
    /// KVO watcher `previewPane(for:)` layers under the mounted `PreviewView` — mirrors
    /// `MarkdownTextView.swift`'s `SentinelView`, reused directly rather than re-implemented,
    /// since a plain `.focused($binding)` can't reach through `PreviewView`'s raw-`WKWebView`
    /// `NSViewRepresentable` (`MarkdownTextView.swift`'s header comment documents why an
    /// `NSHostingView`/SwiftUI-native indirection was tried and dropped for the same reason).
    /// Read by `SiteWindow.navigatorSelectionActions(for:)` to decide whether ⌘D's Duplicate acts
    /// on this canvas's block selection or the Navigator's row selection (menu-bar IA spec: "⌘D
    /// Duplicate is one focus-scoped command").
    var hasKeyboardFocus = false

    /// Bridges this canvas's applied ops into the window's `UndoManager` for real ⌘Z/⇧⌘Z (#1225,
    /// Task 9). Wired via `addOpAppliedListener` below at `init` time, so callers (`PreviewModel`)
    /// don't need to know about undo at all — they only set `undoCoordinator.undoManager`. `lazy`,
    /// same reason as `SiteWindowModel.contentUndoCoordinator`: its `perform` closure captures
    /// `self`, which isn't available yet inside `init` before all stored properties are set.
    /// `@ObservationIgnored`: not view-relevant state, same as `SiteWindowModel`'s coordinators.
    ///
    /// Awaits `apply(_:)` — not `submit(_:)` — to completion and reports whether the op actually
    /// landed. Using `apply(_:)` (which skips `fireOpApplied`) is load-bearing, not a style choice:
    /// `WYSIWYGUndoCoordinator.register` already re-registers the opposite undo/redo direction
    /// itself once this `Performer` returns `true`. If this replayed through `submit(_:)`
    /// instead, `submit`'s own `fireOpApplied` call would *also* reach `registerApplied`, double-
    /// registering the same step and corrupting `UndoManager`'s undo/redo stacks. `.applied` vs.
    /// `.rejected` (e.g. a version-mismatch conflict) decides `true`/`false`, so a rejection that
    /// left the document unchanged never re-registers a (now-wrong) next step either.
    @ObservationIgnored
    lazy var undoCoordinator = WYSIWYGUndoCoordinator { [weak self] op in
        guard let self else { return false }
        switch await self.apply(op) {
        case .applied:
            return true
        case .rejected:
            return false
        }
    }

    /// Fires after every **newly submitted** op, with its inverse — deliberately *not* after an
    /// undo/redo replay, which reaches the model through `apply(_:)` and must not re-register
    /// itself as a new undo step (see `undoCoordinator`'s doc comment). A list rather than a single
    /// closure so future subscribers can coexist without silently overwriting each other, the
    /// failure mode a single-closure property would have.
    ///
    /// Quality-gate re-analysis is **not** wired here: it has to fire on every model change,
    /// including undo/redo, so it hangs off `sendAndApply(_:)` instead — see `runQualityGates`.
    private var opAppliedListeners: [(Op, Op, BlockModel) -> Void] = []

    func addOpAppliedListener(_ listener: @escaping (Op, Op, BlockModel) -> Void) {
        opAppliedListeners.append(listener)
    }

    private func fireOpApplied(_ op: Op, _ inverse: Op, _ model: BlockModel) {
        for listener in opAppliedListeners { listener(op, inverse, model) }
    }

    /// Test-only seam: overrides the `targetVersion` a submitted envelope carries, so a test can
    /// force a version-mismatch rejection without needing two controllers racing a real one.
    var forceTargetVersion: String?

    /// Set by `PreviewView`'s `onWebView` callback (`SiteWindow.previewPane(for:)`) once the
    /// underlying `WKWebView` exists, so `applyFormat(_:href:)` (#1225 Task 10) has something to
    /// call into. Weak: the view owns the web view's lifetime, matching `PreviewModel.webView`'s
    /// own pattern.
    weak var webView: WKWebView?

    /// Set by `PreviewModel.enterEditMode` once the open site's `Source/` directory is known — `nil`
    /// until then, in which case `runQualityGates` below simply has nothing to analyze against yet.
    var qualityGateContext: GateContext?

    /// The most recent quality-gate analysis result, or `nil` before the first applied op (or if
    /// `qualityGateContext` was never set). Exposed for testability without a real `WKWebView` — same
    /// reasoning as `mountScript(for:)`'s split from `mountEngine()` below.
    private(set) var lastQualityGateResult: QualityGateRunner.Result?

    /// The Insert menu's Component submenu source (#1225 Task 12). Static interim stand-in for
    /// the real CEM-aligned theme manifest, which needs #1222's sidecar `get_page_model`-shaped
    /// service that doesn't exist yet — see `WYSIWYGCanvasController.stubBlockPalette`'s doc
    /// comment below.
    let blockPalette: [WYSIWYGBlockPaletteEntry] = WYSIWYGCanvasController.stubBlockPalette

    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        addOpAppliedListener { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
    }

    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let result = await apply(op)
        if case .applied(let newModel) = result {
            fireOpApplied(op, WYSIWYGOpInverter.invert(op), newModel)
        }
        return result
    }

    /// Sends `op` to the transport and updates `model` — the shared core of `submit(_:)`, minus
    /// the applied-op notification. `submit(_:)` is for ops with a *new* opposite direction to
    /// register (user edits); `undoCoordinator`'s `Performer` calls this directly instead, since
    /// undo/redo replays must not re-fire `fireOpApplied` — see `undoCoordinator`'s doc comment for
    /// why that would double-register. Builds its own envelope from the *current* `model.version`
    /// (or `forceTargetVersion`'s test-only override) — unlike `sendOp(_:)` below, which already
    /// has a real envelope from the JS engine and must not re-derive one.
    private func apply(_ op: Op) async -> OpResult {
        let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
        return await sendAndApply(envelope)
    }

    /// Sends `envelope` to the transport verbatim and applies the result to `model` — the shared
    /// core of both `apply(_:)` (which builds a fresh envelope from `model.version`) and
    /// `sendOp(_:)` (the `WYSIWYGHostTransport` conformance below, whose caller — the JS engine —
    /// already computed `targetVersion` and must not have it silently replaced). Does not fire
    /// `fireOpApplied`; callers that need the notification do so themselves after inspecting the
    /// result, same division of responsibility `apply(_:)`/`submit(_:)` already had.
    ///
    /// It *does* re-run the quality gates, though, on every path that actually changes `model` —
    /// this is the one funnel every mutation passes through (`submit(_:)`'s user edits, the undo
    /// coordinator's `apply(_:)` replays, and JS-originated `sendOp(_:)` alike). Hanging the gates
    /// off `addOpAppliedListener` instead left undo/redo silently un-analyzed: undoing a heading
    /// fix put the skip back in the model while its chip stayed cleared, because the undo path
    /// bypasses the listener list on purpose.
    private func sendAndApply(_ envelope: OpEnvelope) async -> OpResult {
        let result = await transport.sendOp(envelope)
        switch result {
        case .applied(let newModel):
            model = newModel
            await runQualityGates(model: newModel)
        case .rejected(_, _, let freshModel):
            if let freshModel {
                model = freshModel
                await runQualityGates(model: freshModel)
            }
        }
        return result
    }

    /// The Edit-menu Duplicate button's canvas-focused target (#1225 Task 11) — extends
    /// `NavigatorEditCommands.Duplicate` (⌘D) rather than adding a second menu item, per the
    /// menu-bar IA spec's "one focus-scoped command" rule (`SiteWindow.navigatorSelectionActions(for:)`
    /// picks this over the Navigator's own duplicate when `hasKeyboardFocus` is true).
    ///
    /// PR1 duplicates at the page root only — locating the block's real parent/slot to insert the
    /// copy adjacent to it needs a parent-lookup helper the model doesn't expose yet; kept out of
    /// scope here and flagged for a PR2 follow-up once the native palette (Task 13) needs the same
    /// lookup for drop-target computation. `rootIds.contains(id)` is load-bearing, not defensive
    /// filler: without it, a `selectedBlockId` pointing at a nested block (inside a slot/container
    /// — not reachable today, but will be once Task 12/13 wire up real block selection) would
    /// still pass the `model.blocks[id]` lookup and get "duplicated" as a brand-new *root-level*
    /// block built from the nested block's content — silently detaching it from its real
    /// structural context instead of no-op'ing, same failure mode `deleteSelectedBlock()` below
    /// already guards against with `rootIds.firstIndex(of:)`.
    func duplicateSelectedBlock() async {
        guard let id = selectedBlockId, let node = model.blocks[id], model.rootIds.contains(id) else { return }
        let newId = UUID().uuidString
        let content = BlockNodeContent(
            kind: node.kind, componentName: node.componentName, props: node.props,
            slots: node.slots, sourceSpan: node.sourceSpan, richText: node.richText)
        await submit(.insertBlock(parentId: rootParentID, slot: "main", index: model.rootIds.count, newId: newId, block: content))
    }

    /// The canvas's own `.onDeleteCommand` target (#1225 Task 11) — reachable only when the canvas
    /// holds real keyboard focus (`hasKeyboardFocus`). `SiteWindow.previewPane(for:)` and
    /// `SiteNavigatorView` both gate their `.onDeleteCommand` attachment on this flag directly
    /// (#1423) rather than leaving both permanently attached for AppKit's responder chain to
    /// arbitrate — that arbitration turned out unreliable for the shared Edit ▸ Delete menu item
    /// once two `.onDeleteCommand`s coexisted, even though it correctly scopes menu-bar IA's "one
    /// focus-scoped command" rule for physical keypresses (matching `duplicateSelectedBlock()`
    /// above, unaffected since Duplicate has no auto-generated menu item to conflict over). PR1
    /// only supports root-level blocks (see
    /// `duplicateSelectedBlock()`'s doc comment) — `rootIds.firstIndex(of:)` returning `nil` for a
    /// nested block just no-ops, same as `guard let node` above.
    func deleteSelectedBlock() async {
        guard let id = selectedBlockId, let node = model.blocks[id], let index = model.rootIds.firstIndex(of: id) else { return }
        await submit(.deleteBlock(parentId: rootParentID, slot: "main", index: index, blockId: id, block: node))
        selectedBlockId = nil
    }

    /// The Insert menu's Component submenu (#1225 Task 12) — appends a brand-new block built
    /// from a palette entry at the page root. Unlike `duplicateSelectedBlock()`, this always
    /// inserts unconditionally at the root regardless of `selectedBlockId`: there's no existing
    /// block to guard against misplacing, since the whole point is adding a *new* one from the
    /// palette, not acting on the current selection.
    func insertBlock(_ entry: WYSIWYGBlockPaletteEntry) async {
        let newId = UUID().uuidString
        let content = BlockNodeContent(kind: entry.kind, componentName: entry.componentName, props: [:], slots: [:], sourceSpan: [0, 0])
        await submit(.insertBlock(parentId: rootParentID, slot: "main", index: model.rootIds.count, newId: newId, block: content))
    }

    /// The Format menu's Strong/Emphasis/Add Link entry point (#1225 Task 10) — posts into the
    /// mounted `RichTextEditor` (`JS/wysiwyg-engine/src/rich-text.ts`) via the same global the
    /// build's `mount.ts` exposes it under. `command` is `"strong"`/`"em"`/`"link"`; `⌘K` (inline
    /// `code`) is out of scope for this task. Fire-and-forget, same as
    /// `ComponentStyleInspectorPane`'s canvas-command calls: the JS side no-ops silently if there's
    /// no active editing session (`RichTextEditor`'s own `#activeElement` guard) or the script
    /// hasn't mounted yet (`?.`), so there is nothing meaningful to await here.
    func applyFormat(_ command: String, href: String? = nil) {
        var script = "window.__anglesiteWysiwygRichTextEditor?.applyFormat(\(Self.jsStringLiteral(command))"
        if let href {
            script += ", \(Self.jsStringLiteral(href))"
        }
        script += ")"
        webView?.evaluateJavaScript(script)
    }

    /// Mounts the JS engine (`JS/wysiwyg-engine/src/host/mount.ts`) against this controller's
    /// current `model` — without this call, `window.__anglesiteWysiwygMount.mount(...)` is never
    /// invoked, so `window.__anglesiteWysiwygEngine`/`__anglesiteWysiwygRichTextEditor` are never
    /// set: the right-click context menu never fires, `applyFormat(_:href:)` above is a permanent
    /// no-op, and no `submit-op` message is ever posted from JS (#1225 final-review fix wave,
    /// Finding 1 — the whole bridge was dead code at runtime before this). Called from
    /// `PreviewModel.enterEditMode(path:undoManager:)` (if the web view is already live) and from
    /// `PreviewView`'s `onWebView`/`updateNSView` (once the web view (re)appears while edit mode is
    /// already on) — see those call sites' doc comments for why both orderings need a call site.
    /// Best-effort: if the page hasn't finished loading yet, `evaluateJavaScript` will report an
    /// error (surfaced nowhere today) or `window.__anglesiteWysiwygMount` won't exist yet, and the
    /// call silently does nothing (JS's own `?.`); the realistic path (the user toggles the Site ▸
    /// Edit Page menu item against an already-`.ready` preview) always has a loaded page.
    func mountEngine() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.mountScript(for: model, displayNames: blockDisplayNames))
    }

    /// The `unmount()` counterpart — disposes the mounted engine/rich-text-editor and clears their
    /// globals so a stale reference can't answer a hit-test or accept an op after the native side
    /// considers edit mode off. Called from `PreviewModel.exitEditMode()` and from `PreviewView`'s
    /// `updateNSView` when it observes the mounted controller change out from under an
    /// already-loaded page (Finding 6's teardown gap — see that method's doc comment).
    func unmountEngine() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.unmountScript)
    }

    /// Builds the `mount(...)` `evaluateJavaScript` string for `model` and `displayNames` — factored
    /// out of `mountEngine()` so it's testable without a real `WKWebView`. `displayNames` maps
    /// `componentName` -> the owner-facing name VoiceOver announces for that block
    /// (`AccessibilityAnnotator`'s `displayName(_:)` on the JS side falls back to the raw
    /// `componentName` for anything not in this map — see `blockPalette`'s own doc comment for why the
    /// map is still a small interim stand-in). Returns a no-op script if either fails to encode
    /// (unreachable in practice — both are plain `Codable`/`Encodable` values).
    static func mountScript(for model: BlockModel, displayNames: [String: String]) -> String {
        guard let modelData = try? JSONEncoder().encode(model), let modelJSON = String(data: modelData, encoding: .utf8),
              let namesData = try? JSONEncoder().encode(displayNames), let namesJSON = String(data: namesData, encoding: .utf8)
        else {
            return ""
        }
        return "window.__anglesiteWysiwygMount?.mount(\(modelJSON), \(namesJSON))"
    }

    /// `componentName -> displayName` built from `blockPalette` — the interim manifest stand-in
    /// `AccessibilityAnnotator` (JS side) uses to label blocks for VoiceOver (#1589). Uses
    /// `uniquingKeysWith:` (keeping the first entry) rather than `uniqueKeysWithValues:` — the palette
    /// is a hardcoded array today, but nothing enforces distinct `componentName`s as it grows, and a
    /// duplicate must not crash the whole mount call over a labeling concern.
    private var blockDisplayNames: [String: String] {
        Dictionary(blockPalette.map { ($0.componentName, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// The `unmount()` counterpart to `mountScript(for:)` — no model to encode, so this is just the
    /// literal call string, kept as a `static let` for the same test-without-`WKWebView` reason.
    static let unmountScript = "window.__anglesiteWysiwygMount?.unmount?.()"

    /// Re-runs all five quality gates against `model` and pushes the result to the engine. Called
    /// from `sendAndApply(_:)` on every model change (see its doc comment for why not from the
    /// applied-op listener list) and once from `PreviewModel.enterEditMode` against the seed model,
    /// so an owner opening a page that already has issues sees its chips without having to make an
    /// edit first. A `nil` `qualityGateContext` or `nil` `webView` both no-op harmlessly — the next
    /// model change re-triggers this the same way.
    ///
    /// `QualityGateRunner.analyze` does real synchronous work per applied op — `ImageWeightGate`
    /// alone stats every image-like block on disk — so it runs inside a detached `Task` rather than
    /// directly on this `@MainActor` type. `model`/`qualityGateContext` are both plain `Sendable`
    /// value types, so capturing them into the detached closure is a safe snapshot, not a shared
    /// reference. Awaiting the detached task's `.value` (rather than firing-and-forgetting it) keeps
    /// `sendAndApply`'s existing "model changed, gates re-run" ordering intact for every caller
    /// (including tests asserting on `lastQualityGateResult` right after an awaited `submit(_:)`) —
    /// the await suspends this method without blocking the main thread while the analysis runs.
    func runQualityGates(model: BlockModel) async {
        guard let qualityGateContext else { return }
        let result = await Task.detached(priority: .utility) {
            QualityGateRunner.analyze(model: model, context: qualityGateContext)
        }.value
        lastQualityGateResult = result
        pushQualityFindings(result.findings)
        for category in result.failedCategories {
            await LogCenter.shared.append(source: "quality-gates", stream: .stderr, text: "\(category.rawValue) checker failed for \(model.path)")
        }
    }

    /// Builds the `_handleQualityFindings` call for `findings` — factored out of
    /// `pushQualityFindings` the same way `mountScript(for:)` is factored out of `mountEngine()`, so
    /// it's testable without a real `WKWebView`. Returns a no-op script on the unreachable case that
    /// `findings` fails to encode.
    static func pushQualityFindingsScript(for findings: [Finding]) -> String {
        guard let data = try? JSONEncoder().encode(findings), let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "window.__anglesiteWysiwygHost?._handleQualityFindings?.(\(json))"
    }

    private func pushQualityFindings(_ findings: [Finding]) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.pushQualityFindingsScript(for: findings))
    }

    /// Escapes a Swift string into a double-quoted JS string literal for `evaluateJavaScript`
    /// interpolation — mirrors `ComponentStyleInspectorPane.jsStringLiteral`, needed here too
    /// since `href` (a future link-URL prompt's user input) isn't safe to interpolate raw.
    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// One entry in the Insert menu's Component submenu (#1225 Task 12) — what `WYSIWYGCanvasController
/// .insertBlock(_:)` builds a new `BlockNodeContent` from.
struct WYSIWYGBlockPaletteEntry: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let kind: BlockKind
    let componentName: String
}

extension WYSIWYGCanvasController {
    /// Static interim palette until #1222's sidecar model service supplies a real
    /// CEM-aligned theme manifest. Kept intentionally small — enough to exercise the Insert
    /// menu's data-driven wiring, not a stand-in for real theme block coverage.
    static let stubBlockPalette: [WYSIWYGBlockPaletteEntry] = [
        WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Paragraph", kind: .text, componentName: "p"),
        WYSIWYGBlockPaletteEntry(id: UUID(), displayName: "Heading", kind: .text, componentName: "h2"),
    ]
}

/// Lets `PreviewView` register `WYSIWYGScriptHandler` directly against the controller instead of
/// reaching into its private `transport` — the handler only ever needs the `WYSIWYGHostTransport`
/// surface, and routing submitted ops through `submit(_:)` keeps `model`/`fireOpApplied` in sync
/// with ops that arrive from JS, exactly like ops submitted natively (menu commands, Task 9's
/// undo coordinator).
extension WYSIWYGCanvasController: WYSIWYGHostTransport {
    /// Forwards `envelope` to the underlying transport **unchanged** — critically, `targetVersion`
    /// is the version the JS engine actually computed `envelope.op` against, not re-derived from
    /// this controller's current `model.version` (that used to happen implicitly by routing through
    /// `submit(_:)`, which silently re-targeted a stale JS-originated op instead of correctly
    /// rejecting it as a version-mismatch conflict — #1225 final-review fix wave, Finding 2). Mirrors
    /// `submit(_:)`'s own "apply, then notify" shape rather than calling `submit(_:)` itself, since
    /// `submit(_:)` builds its own envelope from `model.version`.
    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let result = await sendAndApply(envelope)
        if case .applied(let newModel) = result {
            fireOpApplied(envelope.op, WYSIWYGOpInverter.invert(envelope.op), newModel)
        }
        return result
    }

    /// No-op for now: PR1 has no host-initiated push into an already-mounted controller (no
    /// external-edit trigger exists yet — see `StubWYSIWYGHostTransport.onModelUpdate`). `async`
    /// to match `WYSIWYGHostTransport`'s protocol requirement.
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> @Sendable () -> Void {
        {}
    }
}
