import Foundation
import AnglesiteCore

/// A portable 2D point — `AnglesiteBridgeCore` is built on Linux (no `CoreGraphics`), so
/// `DispatchResult.contextMenu` can't carry a `CGPoint` directly. Darwin-only consumers
/// (`WYSIWYGScriptHandler`) convert this to `CGPoint` at their own boundary.
public struct WYSIWYGPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Webview-agnostic message schema + routing for the `wysiwyg` script-message namespace — the
/// **single** JS → native channel every injected page script posts to since #1957 retired the
/// click-to-edit overlay and its `anglesite` namespace (cross-platform port design §6
/// "AnglesiteBridgeCore split"). Each platform's webview adapter (`WKWebView` today; WebKitGTK/
/// WebView2 later) forwards the raw decoded message body here and gets back a `DispatchResult`
/// describing what to do next — the adapter's only remaining job is shuttling bytes in and out of
/// its native webview API.
///
/// Two families of message ride this bridge:
///
/// **Block-engine messages** (`JS/wysiwyg-engine/src/host/mount.ts`, present only while a canvas
/// is mounted): `submit-op`, an `OpEnvelope` the engine sends when the owner performs a gesture
/// (the reply is the resulting `OpResult`); `context-menu`, the engine's hit-test result on a
/// native `contextmenu` DOM event (spec §8.1 — the host builds a real `NSMenu`, no reply);
/// `selection-changed`, the engine's own selection state changing (no reply); `focus-inspector`,
/// `KeyboardNavigation`'s Tab/Shift-Tab request to move real AppKit focus into the native
/// inspector (#1616, no reply); `writing-help-request`, text + an instruction for the on-device
/// rewrite assistant (#1227 PR 2 — the reply is the outcome keyed by `requestId`); and
/// `replace-image`, a file dropped onto an existing `<img>` (#1957 — the reply is the sidecar's
/// `EditReply` for the `replace-image-src` `apply_edit` op, keyed by `requestId`).
///
/// **Page-bridge messages** (`JS/wysiwyg-engine/src/host/page-bridge.ts`, posted on every page
/// whether or not an engine is mounted, none expecting a reply): `anglesite:visible-elements`
/// (a `VisibleElementReport`, #145 — Siri's onscreen awareness), `anglesite:canvas-selection` +
/// `anglesite:computed-styles` (the Component Editor's harness canvas, `component-canvas.ts`),
/// `anglesite:pick-placement` (the Effects gallery's click-to-place, #768) and
/// `anglesite:pick-goal-element` (the experiment goal picker, #1518). Their `type` strings keep
/// the `anglesite:` prefix as wire vocabulary — that's what `VisibleElementReport.decode` and
/// friends match on — even though the *namespace* they arrive on is `wysiwyg`.
public enum WYSIWYGOpsDispatcher {
    /// The `WKUserContentController`/`WebKitUserContentManager`/WebView2 script-message name
    /// every platform adapter registers its handler under — the page posts messages here
    /// regardless of which native webview it's running in.
    public static let scriptMessageNamespace = "wysiwyg"

    /// Which end of the native inspector's prop fields a `focus-inspector` request should land
    /// on — `forward` (Tab) the first field, `backward` (Shift-Tab) the last, mirroring how
    /// tabbing backward into a preceding control conventionally lands on its last stop.
    public enum FocusDirection: String, Sendable {
        case forward
        case backward
    }

    /// Answers a `writing-help-request` with a rewrite outcome (#1227 PR 2).
    public typealias WritingHelper = @Sendable (_ text: String, _ instruction: String) async -> WritingHelpOutcome
    /// Applies a `replace-image` request as a `replace-image-src` `EditMessage` — in production
    /// `EditRouter.apply(_:)` on the preview's registered router (`PreviewView`), so the drop
    /// lands through the same sidecar path (optimize, strip metadata, one commit) the overlay's
    /// `anglesite:apply-edit` used to.
    public typealias ImageReplacer = @Sendable (EditMessage) async -> EditReply
    /// Receives the decoded elements of an `anglesite:visible-elements` report. Async so
    /// implementations can hop to their model's actor; no reply flows back.
    public typealias VisibleElementsHandler = @Sendable ([VisibleElement]) async -> Void
    /// Receives a decoded `anglesite:canvas-selection` message.
    public typealias CanvasSelectionHandler = @Sendable (CanvasSelectionMessage) async -> Void
    /// Receives a decoded `anglesite:computed-styles` report.
    public typealias ComputedStylesHandler = @Sendable (ComputedStylesReport) async -> Void
    /// Receives a decoded `anglesite:pick-placement` message.
    public typealias PlacementPickHandler = @Sendable (PlacementPickMessage) async -> Void
    /// Receives a decoded `anglesite:pick-goal-element` message.
    public typealias GoalElementPickHandler = @Sendable (GoalElementPickMessage) async -> Void

    /// The optional per-message consumers an adapter installs. Every field is `nil` by default:
    /// a message whose consumer is absent is reported as *dropped* (page-bridge messages) or
    /// answered with an "unavailable" reply (`writing-help-request`, `replace-image`) rather
    /// than rejected — the wiring that's missing is the adapter's business to log.
    public struct Handlers: Sendable {
        public var writingHelp: WritingHelper?
        public var imageReplace: ImageReplacer?
        public var onVisibleElements: VisibleElementsHandler?
        public var onCanvasSelection: CanvasSelectionHandler?
        public var onComputedStyles: ComputedStylesHandler?
        public var onPlacementPick: PlacementPickHandler?
        public var onGoalElementPick: GoalElementPickHandler?

        public init(
            writingHelp: WritingHelper? = nil,
            imageReplace: ImageReplacer? = nil,
            onVisibleElements: VisibleElementsHandler? = nil,
            onCanvasSelection: CanvasSelectionHandler? = nil,
            onComputedStyles: ComputedStylesHandler? = nil,
            onPlacementPick: PlacementPickHandler? = nil,
            onGoalElementPick: GoalElementPickHandler? = nil
        ) {
            self.writingHelp = writingHelp
            self.imageReplace = imageReplace
            self.onVisibleElements = onVisibleElements
            self.onCanvasSelection = onCanvasSelection
            self.onComputedStyles = onComputedStyles
            self.onPlacementPick = onPlacementPick
            self.onGoalElementPick = onGoalElementPick
        }
    }

    public enum DispatchResult: Sendable {
        /// `submit-op` was applied against the transport; the adapter should reply with `result`
        /// keyed by `requestId` (the envelope's `id`).
        case opResult(requestId: String, result: OpResult)
        /// `context-menu` reported the block under the right-clicked point; the adapter should
        /// present a host-native menu there. No reply is sent back to the page.
        case contextMenu(blockId: BlockId, point: WYSIWYGPoint)
        /// `selection-changed` reported the engine's own selection state changing (a click,
        /// keyboard nav, or any other engine-internal cause) — `blockId` is `nil` when the
        /// selection was cleared. The adapter should update its `selectedBlockId` so
        /// Duplicate/Delete keep acting on the right block. No reply is sent back to the page,
        /// same as `contextMenu`.
        case selectionChanged(blockId: BlockId?)
        /// `focus-inspector` requested the native inspector take real AppKit keyboard focus
        /// (#1616) — the adapter should move focus to its first (`.forward`) or last
        /// (`.backward`) prop field. `blockId` is the block that was selected in JS at the
        /// moment Tab was pressed — the adapter should adopt it as `selectedBlockId` itself
        /// rather than trust that value already being in sync: it's normally kept in sync by the
        /// separate `selection-changed` message above, posted and dispatched independently, so a
        /// fast select-then-Tab could otherwise land this request against a stale prior
        /// selection. No reply is sent back to the page.
        case focusInspector(direction: FocusDirection, blockId: BlockId)
        /// `writing-help-request` carried text + an instruction for the on-device rewrite
        /// assistant (#1227 PR 2) — the adapter should reply with `outcome` keyed by `requestId`,
        /// same reply shape as `opResult` above.
        case writingHelpReply(requestId: String, outcome: WritingHelpOutcome)
        /// `replace-image` carried a dropped file plus the `<img>`'s `ElementInfo` (#1957) — the
        /// adapter should reply with `reply` keyed by `requestId`, same reply shape as `opResult`.
        /// The page swaps to `reply.result`'s `src`/`srcset` on `.applied` and reverts otherwise.
        case imageReplaceReply(requestId: String, reply: EditReply)
        /// `anglesite:visible-elements` was forwarded to `Handlers.onVisibleElements`.
        case visibleElementsHandled
        /// `anglesite:visible-elements` arrived but no `onVisibleElements` handler is installed.
        case visibleElementsDropped
        /// `anglesite:canvas-selection` was forwarded to `Handlers.onCanvasSelection`.
        case canvasSelectionHandled
        /// `anglesite:canvas-selection` arrived but no `onCanvasSelection` handler is installed.
        case canvasSelectionDropped
        /// `anglesite:computed-styles` was forwarded to `Handlers.onComputedStyles`.
        case computedStylesHandled
        /// `anglesite:computed-styles` arrived but no `onComputedStyles` handler is installed.
        case computedStylesDropped
        /// `anglesite:pick-placement` was forwarded to `Handlers.onPlacementPick`.
        case placementPickHandled
        /// `anglesite:pick-placement` arrived but no `onPlacementPick` handler is installed.
        case placementPickDropped
        /// `anglesite:pick-goal-element` was forwarded to `Handlers.onGoalElementPick`.
        case goalElementPickHandled
        /// `anglesite:pick-goal-element` arrived but no `onGoalElementPick` handler is installed.
        case goalElementPickDropped
        /// Body was undecodable, or named a message this adapter can't serve. Log and move on.
        case rejected(RejectionReason)

        public enum RejectionReason: Sendable, Equatable {
            /// The body wasn't a dictionary at all.
            case notAnObject
            /// The body has no `type` field.
            case missingType
            /// The `type` field isn't a string.
            case wrongType
            /// The `type` string doesn't name any known message; carries the unrecognized value.
            case unknownType(String)
            /// A block-engine message's payload failed to decode; carries a description.
            case envelopeDecode(String)
            /// `submit-op` arrived on a web view with no block engine transport — a page that
            /// hosts only the page bridge (the Component Editor's harness canvas, the iOS/Linux
            /// previews) — so there is nothing to apply the op against.
            case noTransport
            /// `anglesite:visible-elements` matched but the payload failed to decode.
            case visibleElementsDecode(VisibleElementReport.DecodeError)
            /// `anglesite:canvas-selection` matched but the payload failed to decode.
            case canvasSelectionDecode(ComponentCanvasDecodeError)
            /// `anglesite:computed-styles` matched but the payload failed to decode.
            case computedStylesDecode(ComponentCanvasDecodeError)
            /// `anglesite:pick-placement` matched but the payload failed to decode.
            case placementPickDecode(ComponentCanvasDecodeError)
            /// `anglesite:pick-goal-element` matched but the payload failed to decode.
            case goalElementPickDecode(ComponentCanvasDecodeError)
        }
    }

    /// Peek at the `type` field, dispatch to the matching decoder, and route. Pure — no I/O
    /// beyond the transport and handler calls. `transport` is `nil` on a web view that hosts
    /// only the page bridge (no mounted block engine); a `submit-op` arriving there is
    /// `.rejected(.noTransport)`.
    public static func dispatch(
        body: Any, via transport: (any WYSIWYGHostTransport)?, handlers: Handlers = Handlers()
    ) async -> DispatchResult {
        guard let dict = body as? [String: Any] else { return .rejected(.notAnObject) }
        guard let rawType = dict["type"] else { return .rejected(.missingType) }
        guard let typeStr = rawType as? String else { return .rejected(.wrongType) }

        switch typeStr {
        case "submit-op":
            guard let payload = dict["envelope"],
                  JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let envelope = try? JSONDecoder().decode(OpEnvelope.self, from: data)
            else {
                return .rejected(.envelopeDecode("could not decode OpEnvelope from \"envelope\" field"))
            }
            guard let transport else { return .rejected(.noTransport) }
            let result = await transport.sendOp(envelope)
            return .opResult(requestId: envelope.id, result: result)
        case "context-menu":
            guard let blockId = dict["blockId"] as? String,
                  let x = dict["x"] as? Double, let y = dict["y"] as? Double
            else {
                return .rejected(.envelopeDecode("could not decode context-menu fields"))
            }
            return .contextMenu(blockId: blockId, point: WYSIWYGPoint(x: x, y: y))
        case "selection-changed":
            // `blockId` is legitimately absent/null (selection cleared) — unlike context-menu's
            // required blockId, this isn't a decode failure.
            return .selectionChanged(blockId: dict["blockId"] as? String)
        case "focus-inspector":
            guard let rawDirection = dict["direction"] as? String, let direction = FocusDirection(rawValue: rawDirection),
                  let blockId = dict["blockId"] as? String
            else {
                return .rejected(.envelopeDecode("could not decode focus-inspector fields"))
            }
            return .focusInspector(direction: direction, blockId: blockId)
        case "writing-help-request":
            guard let requestId = dict["requestId"] as? String,
                  let text = dict["text"] as? String,
                  let instruction = dict["instruction"] as? String
            else {
                return .rejected(.envelopeDecode("could not decode writing-help-request fields"))
            }
            let outcome = await handlers.writingHelp?(text, instruction)
                ?? .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
            return .writingHelpReply(requestId: requestId, outcome: outcome)
        case "replace-image":
            guard let requestId = dict["requestId"] as? String,
                  let request = dict["request"] as? [String: Any],
                  let path = request["path"] as? String,
                  let selector = request["selector"] as? [String: Any],
                  let filename = request["filename"] as? String,
                  let mimeType = request["mimeType"] as? String,
                  let dataURL = request["dataURL"] as? String
            else {
                return .rejected(.envelopeDecode("could not decode replace-image fields"))
            }
            // Re-shaped into the `apply-edit` wire body `EditMessage.decode` already validates
            // (selector must be an object, etc.) rather than a second hand-rolled decoder.
            let editBody: [String: Any] = [
                "id": requestId,
                "type": EditMessage.MessageType.applyEdit.rawValue,
                "path": path,
                "selector": selector,
                "op": EditMessage.Op.replaceImageSrc,
                "value": ["filename": filename, "mimeType": mimeType, "dataURL": dataURL],
            ]
            guard case .success(let message) = EditMessage.decode(from: editBody) else {
                return .rejected(.envelopeDecode("could not decode replace-image request as an EditMessage"))
            }
            guard let imageReplace = handlers.imageReplace else {
                return .imageReplaceReply(
                    requestId: requestId,
                    reply: EditReply(id: requestId, status: .failed, message: "Image replacement isn't available in this preview"))
            }
            return .imageReplaceReply(requestId: requestId, reply: await imageReplace(message))

        case VisibleElementReport.messageType:
            switch VisibleElementReport.decode(from: body) {
            case .success(let report):
                guard let handler = handlers.onVisibleElements else { return .visibleElementsDropped }
                await handler(report.elements)
                return .visibleElementsHandled
            case .failure(let error):
                return .rejected(.visibleElementsDecode(error))
            }
        case CanvasSelectionMessage.messageType:
            switch CanvasSelectionMessage.decode(from: body) {
            case .success(let message):
                guard let handler = handlers.onCanvasSelection else { return .canvasSelectionDropped }
                await handler(message)
                return .canvasSelectionHandled
            case .failure(let error):
                return .rejected(.canvasSelectionDecode(error))
            }
        case ComputedStylesReport.messageType:
            switch ComputedStylesReport.decode(from: body) {
            case .success(let report):
                guard let handler = handlers.onComputedStyles else { return .computedStylesDropped }
                await handler(report)
                return .computedStylesHandled
            case .failure(let error):
                return .rejected(.computedStylesDecode(error))
            }
        case PlacementPickMessage.messageType:
            switch PlacementPickMessage.decode(from: body) {
            case .success(let message):
                guard let handler = handlers.onPlacementPick else { return .placementPickDropped }
                await handler(message)
                return .placementPickHandled
            case .failure(let error):
                return .rejected(.placementPickDecode(error))
            }
        case GoalElementPickMessage.messageType:
            switch GoalElementPickMessage.decode(from: body) {
            case .success(let message):
                guard let handler = handlers.onGoalElementPick else { return .goalElementPickDropped }
                await handler(message)
                return .goalElementPickHandled
            case .failure(let error):
                return .rejected(.goalElementPickDecode(error))
            }
        default:
            return .rejected(.unknownType(typeStr))
        }
    }
}
