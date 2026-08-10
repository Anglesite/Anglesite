import Foundation
import AnglesiteCore

/// Webview-agnostic message schema + routing for the `wysiwyg` script-message namespace —
/// deliberately separate from `AnglesiteMessageDispatcher` (the older edit-overlay protocol).
/// One message type today: `submit-op`, an `OpEnvelope` the engine sends when the owner performs
/// a gesture; the reply is the resulting `OpResult`.
public enum WYSIWYGOpsDispatcher {
    public static let scriptMessageNamespace = "wysiwyg"

    public enum DispatchResult: Sendable {
        /// `submit-op` was applied against the transport; the adapter should reply with `result`
        /// keyed by `requestId` (the envelope's `id`).
        case opResult(requestId: String, result: OpResult)
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
        default:
            return .rejected(.unknownType(typeStr))
        }
    }
}
