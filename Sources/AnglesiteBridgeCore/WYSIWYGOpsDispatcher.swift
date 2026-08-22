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

/// Webview-agnostic message schema + routing for the `wysiwyg` script-message namespace —
/// deliberately separate from `AnglesiteMessageDispatcher` (the older edit-overlay protocol).
/// Three message types: `submit-op`, an `OpEnvelope` the engine sends when the owner performs a
/// gesture (the reply is the resulting `OpResult`); `context-menu`, the engine's hit-test result
/// on a native `contextmenu` DOM event (spec §8.1 — the host builds a real `NSMenu`, no reply
/// expected); and `selection-changed`, the engine's own selection state changing (no reply
/// expected).
public enum WYSIWYGOpsDispatcher {
    public static let scriptMessageNamespace = "wysiwyg"

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
        case rejected(RejectionReason)

        public enum RejectionReason: Sendable, Equatable {
            case notAnObject
            case missingType
            case wrongType
            case unknownType(String)
            case envelopeDecode(String)
        }
    }

    public static func dispatch(body: Any, via transport: any WYSIWYGHostTransport) async -> DispatchResult {
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
        default:
            return .rejected(.unknownType(typeStr))
        }
    }
}
