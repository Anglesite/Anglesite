// Sources/AnglesiteIOS/NavigationRestorationModel.swift
import Foundation
import Observation

/// What the composer column should restore to: a fresh composition of a type, or a specific
/// existing post. Mirrors `AnglesiteMobile`'s `PostListItemSelection`, minus the full
/// `PostListModel.Item` an existing selection carries in memory — only the post's URL (its
/// identity) is worth persisting; the item itself is re-resolved once the post list reloads.
public enum PersistedSelection: Codable, Equatable, Sendable {
    case new(typeID: String)
    case existing(postURL: URL)
}

/// Persists the iOS shell's navigation position — the content-type filter and post selection
/// within the currently-selected site — and which sites have a warm "Edit Site" session, so a
/// relaunch can restore both (#1436, iOS v2.0 design §8.6). Kept separate from
/// `SiteSelectionModel`, which owns the site choice itself: that model already resolves once
/// discovery produces a site list, and this one restores against whichever site it resolved to.
@MainActor
@Observable
public final class NavigationRestorationModel {
    /// The position bundle: a content-type filter and selection, tagged with the site they
    /// belong to so a stale bundle from a previously-selected site is never misapplied after a
    /// site switch.
    private struct PositionBundle: Codable {
        let siteID: UUID
        let typeID: String?
        let selection: PersistedSelection?
    }

    public private(set) var warmSessionIDs: Set<UUID> = []

    private let defaults: UserDefaults
    private static let positionKey = "navigationRestoration.position"
    private static let warmSessionIDsKey = "navigationRestoration.warmSessionIDs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.warmSessionIDsKey),
           let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            warmSessionIDs = ids
        }
    }

    /// Records the current content-type filter and post selection for `siteID`. Call on every
    /// change, not just on backgrounding — a cheap synchronous write, and the only way to avoid
    /// losing position to memory pressure rather than an orderly background transition.
    public func recordPosition(siteID: UUID, typeID: String?, selection: PersistedSelection?) {
        let bundle = PositionBundle(siteID: siteID, typeID: typeID, selection: selection)
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        defaults.set(data, forKey: Self.positionKey)
    }

    /// The persisted position for `siteID`, or `nil` when nothing was recorded for it — either
    /// because nothing has been recorded yet, or the persisted bundle belongs to a different
    /// site (the owner switched sites since it was written).
    public func restorePosition(forSite siteID: UUID) -> (typeID: String?, selection: PersistedSelection?)? {
        guard let data = defaults.data(forKey: Self.positionKey),
              let bundle = try? JSONDecoder().decode(PositionBundle.self, from: data),
              bundle.siteID == siteID
        else { return nil }
        return (bundle.typeID, bundle.selection)
    }

    /// Marks `siteID` as having a live/starting "Edit Site" session — call whenever an
    /// `EditSessionModel`'s phase becomes `.waking`, `.starting`, or `.ready`.
    public func markSessionWarm(siteID: UUID) {
        guard warmSessionIDs.insert(siteID).inserted else { return }
        persistWarmSessionIDs()
    }

    /// Clears `siteID`'s warm-session marker — call when its `EditSessionModel`'s phase becomes
    /// `.idle`, `.failed`, or `.pairingRequired`, or when the owner explicitly declines a
    /// "Continue editing…" offer.
    public func markSessionEnded(siteID: UUID) {
        guard warmSessionIDs.remove(siteID) != nil else { return }
        persistWarmSessionIDs()
    }

    private func persistWarmSessionIDs() {
        guard let data = try? JSONEncoder().encode(warmSessionIDs) else { return }
        defaults.set(data, forKey: Self.warmSessionIDsKey)
    }
}
