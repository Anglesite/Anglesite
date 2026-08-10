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
    /// Task 9). Wired to `onOpApplied` below at `init` time, so callers (`PreviewModel`) don't
    /// need to know about undo at all — they only set `undoCoordinator.undoManager`. `lazy`,
    /// same reason as `SiteWindowModel.contentUndoCoordinator`: its `perform` closure captures
    /// `self`, which isn't available yet inside `init` before all stored properties are set.
    /// `@ObservationIgnored`: not view-relevant state, same as `SiteWindowModel`'s coordinators.
    ///
    /// Awaits `apply(_:)` — not `submit(_:)` — to completion and reports whether the op actually
    /// landed. Using `apply(_:)` (which skips `onOpApplied`) is load-bearing, not a style choice:
    /// `WYSIWYGUndoCoordinator.register` already re-registers the opposite undo/redo direction
    /// itself once this `Performer` returns `true`. If this replayed through `submit(_:)`
    /// instead, `submit`'s own `onOpApplied` firing would *also* call `registerApplied`, double-
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

    /// Fires after every successfully applied op, with its inverse — set at `init` time to feed
    /// `undoCoordinator`. Still overridable by tests/other callers that need their own hook,
    /// same seam as before Task 9.
    var onOpApplied: ((Op, Op, BlockModel) -> Void)?

    /// Test-only seam: overrides the `targetVersion` a submitted envelope carries, so a test can
    /// force a version-mismatch rejection without needing two controllers racing a real one.
    var forceTargetVersion: String?

    /// Set by `PreviewView`'s `onWebView` callback (`SiteWindow.previewPane(for:)`) once the
    /// underlying `WKWebView` exists, so `applyFormat(_:href:)` (#1225 Task 10) has something to
    /// call into. Weak: the view owns the web view's lifetime, matching `PreviewModel.webView`'s
    /// own pattern.
    weak var webView: WKWebView?

    /// The Insert menu's Component submenu source (#1225 Task 12). Static interim stand-in for
    /// the real CEM-aligned theme manifest, which needs #1222's sidecar `get_page_model`-shaped
    /// service that doesn't exist yet — see `WYSIWYGCanvasController.stubBlockPalette`'s doc
    /// comment below.
    let blockPalette: [WYSIWYGBlockPaletteEntry] = WYSIWYGCanvasController.stubBlockPalette

    init(initialModel: BlockModel, transport: any WYSIWYGHostTransport) {
        self.model = initialModel
        self.transport = transport
        onOpApplied = { [weak self] op, inverse, _ in
            self?.undoCoordinator.registerApplied(op: op, inverse: inverse)
        }
    }

    @discardableResult
    func submit(_ op: Op) async -> OpResult {
        let result = await apply(op)
        if case .applied(let newModel) = result {
            onOpApplied?(op, WYSIWYGOpInverter.invert(op), newModel)
        }
        return result
    }

    /// Sends `op` to the transport and updates `model` — the shared core of `submit(_:)`, minus
    /// the `onOpApplied` notification. `submit(_:)` is for ops with a *new* opposite direction to
    /// register (user edits, JS-originated ops via `sendOp(_:)`); `undoCoordinator`'s `Performer`
    /// calls this directly instead, since undo/redo replays must not re-fire `onOpApplied` — see
    /// `undoCoordinator`'s doc comment for why that would double-register.
    private func apply(_ op: Op) async -> OpResult {
        let envelope = OpEnvelope(id: UUID().uuidString, targetVersion: forceTargetVersion ?? model.version, op: op)
        let result = await transport.sendOp(envelope)
        switch result {
        case .applied(let newModel):
            model = newModel
        case .rejected(_, _, let freshModel):
            if let freshModel { model = freshModel }
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

    /// The canvas's own `.onDeleteCommand` target (#1225 Task 11) — reachable only when the
    /// canvas holds real keyboard focus (`hasKeyboardFocus`), so AppKit's responder chain decides
    /// whether a bare Delete keypress reaches this or `SiteNavigatorView`'s `.onDeleteCommand`,
    /// rather than a second Commands-level Delete button (menu-bar IA spec, same rule as
    /// `duplicateSelectedBlock()` above). PR1 only supports root-level blocks (see
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
/// surface, and routing submitted ops through `submit(_:)` keeps `model`/`onOpApplied` in sync
/// with ops that arrive from JS, exactly like ops submitted natively (menu commands, Task 9's
/// undo coordinator).
extension WYSIWYGCanvasController: WYSIWYGHostTransport {
    func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        await submit(envelope.op)
    }

    /// No-op for now: PR1 has no host-initiated push into an already-mounted controller (no
    /// external-edit trigger exists yet — see `StubWYSIWYGHostTransport.onModelUpdate`). `async`
    /// to match `WYSIWYGHostTransport`'s protocol requirement.
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> @Sendable () -> Void {
        {}
    }
}
