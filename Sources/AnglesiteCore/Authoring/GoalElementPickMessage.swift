import Foundation

/// The overlay's goal-element-pick mode (Task 4) reporting a click on an arbitrary element while
/// the owner is choosing the target for an A/B experiment's "visible" goal (#1270 slice 5).
/// Structurally identical to `PlacementPickMessage` (same `ElementInfo` payload, same "no reply
/// sent to the page" contract) but a distinct message type/handler — this pick feeds
/// `GoalSelectorBuilder`, not `PlacementMatcher`/an applied edit.
public struct GoalElementPickMessage: Sendable, Equatable {
    public static let messageType = "anglesite:pick-goal-element"

    public let path: String
    public let element: ElementInfo

    public init(path: String, element: ElementInfo) {
        self.path = path
        self.element = element
    }

    /// Decodes a `WKScriptMessage` body. Returns `.failure(.wrongType)` for another message's
    /// body so the dispatcher can try the next decoder; `.malformed` when `type` matches but
    /// `path`/`selector` (or `selector`'s required `tag`/`nthChild`) are missing.
    public static func decode(from body: Any) -> Result<GoalElementPickMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let path = dict["path"] as? String,
              let selectorDict = dict["selector"] as? [String: Any],
              let element = ElementInfo.decode(from: selectorDict) else {
            return .failure(.malformed)
        }
        return .success(GoalElementPickMessage(path: path, element: element))
    }
}
