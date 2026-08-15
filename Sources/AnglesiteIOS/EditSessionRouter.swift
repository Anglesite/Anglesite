import Foundation
import Observation

/// Hands "open this site for editing" requests from App Intents to the iOS shell — the
/// `WindowRouter` pattern (#1431): both ends of the hand-off (an intent's `perform()` on one
/// side, `SiteSplitScreen` observing on the other) have no common injection point, so a
/// process-wide singleton bridges them. Tests construct their own instances.
@MainActor
@Observable
public final class EditSessionRouter {
    /// The process-wide router the intent and the shell share.
    public static let shared = EditSessionRouter()

    /// The site the most recent intent asked to edit; the shell clears it via ``consume()``.
    /// Re-requesting overwrites (last request wins).
    public private(set) var requestedSiteID: UUID?

    public init() {}

    /// Records a request; the observing shell presents the session cover for it.
    public func requestEditSession(siteID: UUID) {
        requestedSiteID = siteID
    }

    /// Returns and clears the pending request — consumed exactly once.
    public func consume() -> UUID? {
        defer { requestedSiteID = nil }
        return requestedSiteID
    }
}
