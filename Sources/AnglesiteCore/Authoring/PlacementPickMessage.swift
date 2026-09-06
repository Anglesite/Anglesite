import Foundation

/// One ancestor in a clicked element's root-first chain, as collected by the overlay's
/// `elementInfoFor()`/`collectAncestors()` (JS/edit-overlay/src/selector.ts). Mirrors
/// `AncestorInfo` there field-for-field.
public struct AncestorInfo: Sendable, Equatable {
    public let tag: String
    public let id: String?
    public let classes: [String]
    public let nthChild: Int?
    public let role: String?
    public let ariaLabel: String?

    public init(tag: String, id: String?, classes: [String], nthChild: Int?, role: String?, ariaLabel: String?) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.nthChild = nthChild
        self.role = role
        self.ariaLabel = ariaLabel
    }

    /// Decodes one entry from the wire's `ancestors` array. Returns `nil` (skipped by the
    /// caller) rather than throwing on a malformed entry — a best-effort ancestor chain is
    /// still useful to `PlacementMatcher` even if one hop is missing fields.
    static func decode(from dict: [String: Any]) -> AncestorInfo? {
        guard let tag = dict["tag"] as? String else { return nil }
        return AncestorInfo(
            tag: tag,
            id: dict["id"] as? String,
            classes: dict["classes"] as? [String] ?? [],
            nthChild: dict["nthChild"] as? Int,
            role: dict["role"] as? String,
            ariaLabel: dict["ariaLabel"] as? String
        )
    }
}

/// Structured element metadata collected by the overlay's `elementInfoFor()` — the same shape
/// `EditMessage.selector` relays opaquely to the sidecar's `selector.mjs`, but here decoded
/// field-by-field because `PlacementMatcher` (Task 7) interprets it client-side against a
/// fetched `PageModel` instead of forwarding it server-side.
public struct ElementInfo: Sendable, Equatable {
    public let tag: String
    public let id: String?
    public let classes: [String]
    public let nthChild: Int
    /// Root-first ancestor chain, stopping at (and including) `<body>`.
    public let ancestors: [AncestorInfo]
    public let dataAnglesiteId: String?
    public let dataTestId: String?
    public let role: String?
    public let ariaLabel: String?
    public let textContent: String?

    public init(tag: String, id: String?, classes: [String], nthChild: Int, ancestors: [AncestorInfo], dataAnglesiteId: String?, dataTestId: String?, role: String?, ariaLabel: String?, textContent: String?) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.nthChild = nthChild
        self.ancestors = ancestors
        self.dataAnglesiteId = dataAnglesiteId
        self.dataTestId = dataTestId
        self.role = role
        self.ariaLabel = ariaLabel
        self.textContent = textContent
    }

    static func decode(from dict: [String: Any]) -> ElementInfo? {
        guard let tag = dict["tag"] as? String, let nthChild = dict["nthChild"] as? Int else { return nil }
        let ancestorDicts = dict["ancestors"] as? [[String: Any]] ?? []
        return ElementInfo(
            tag: tag,
            id: dict["id"] as? String,
            classes: dict["classes"] as? [String] ?? [],
            nthChild: nthChild,
            ancestors: ancestorDicts.compactMap(AncestorInfo.decode(from:)),
            dataAnglesiteId: dict["dataAnglesiteId"] as? String,
            dataTestId: dict["dataTestId"] as? String,
            role: dict["role"] as? String,
            ariaLabel: dict["ariaLabel"] as? String,
            textContent: dict["textContent"] as? String
        )
    }
}

/// The overlay's placement-pick mode (Task 9) reporting a click on an arbitrary element while
/// the app is placing an effect. Distinct from `anglesite:apply-edit` — no reply is sent back
/// into the page; the whole match/apply/refresh flow (Task 10) runs natively and updates the
/// app's own placement HUD.
public struct PlacementPickMessage: Sendable, Equatable {
    public static let messageType = "anglesite:pick-placement"

    public let path: String
    public let element: ElementInfo

    public init(path: String, element: ElementInfo) {
        self.path = path
        self.element = element
    }

    /// Decodes a `WKScriptMessage` body. Returns `.failure(.wrongType)` for another message's
    /// body so the dispatcher can try the next decoder; `.malformed` when `type` matches but
    /// `path`/`selector` (or `selector`'s required `tag`/`nthChild`) are missing.
    public static func decode(from body: Any) -> Result<PlacementPickMessage, ComponentCanvasDecodeError> {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType else {
            return .failure(.wrongType)
        }
        guard let path = dict["path"] as? String,
              let selectorDict = dict["selector"] as? [String: Any],
              let element = ElementInfo.decode(from: selectorDict) else {
            return .failure(.malformed)
        }
        return .success(PlacementPickMessage(path: path, element: element))
    }
}
