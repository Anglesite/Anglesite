// Sources/AnglesiteApp/MicropubSessionResolver.swift
import Foundation
import AnglesiteCore
import AnglesiteIOS

/// Resolves a ready-to-use `MicropubClient` for a site, or `nil` when no CMS-mode session has
/// been onboarded yet (or the stored session was signed out). Shared by every Mac call site that
/// needs "does this site have a working Micropub session right now" — `TypedEntryEditorModel`'s
/// CMS-mode save branch (#800) and `RestrictedPostPublisher`'s restricted-post create path
/// (#1566) — so there is exactly one implementation of that resolution on the Mac side.
enum MicropubSessionResolver {
    typealias Factory = @Sendable (_ siteID: String, _ sourceDirectory: URL) async -> MicropubClient?

    /// Production factory: resolves the session via `StoredMicropubSessions` (Keychain read +
    /// endpoint re-discovery — discovery is never persisted) and builds a client from it.
    static func defaultFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> Factory {
        { siteID, sourceDirectory in
            await sessions.session(siteID: siteID, sourceDirectory: sourceDirectory)?.makeClient()
        }
    }
}
