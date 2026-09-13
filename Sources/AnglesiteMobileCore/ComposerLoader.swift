import Foundation
import AnglesiteCore
import AnglesiteIOS

/// Why the composer pane couldn't open a selection. The view maps each case to localized copy
/// (the strings stay in the app target for String Catalog extraction); the classification is
/// what's tested here.
public enum ComposerLoadFailure: Error, Equatable, Sendable {
    /// `.new` named a type id the registry doesn't know.
    case unavailableContentType
    /// `.existing` post's collection isn't a registered type — nothing this app can edit.
    case uneditablePostType
    /// The `q=source` fetch for an existing post failed (network, auth, or an undecodable post).
    case postFetchFailed
}

/// What the composer pane was asked to open: a fresh composition of a type, or an existing
/// post together with the descriptor the post list resolved for it (`nil` when the list
/// couldn't — the loader turns that into ``ComposerLoadFailure/uneditablePostType``).
public enum ComposerLoadRequest: Equatable, Sendable {
    case new(typeID: String)
    case existing(postURL: URL, descriptor: ContentTypeDescriptor?)

    /// The request for a list selection, resolving an existing item's type through `postList`.
    ///
    /// - Parameters:
    ///   - selection: The composer column's selection.
    ///   - postList: The site's post list, which knows each row's collection → type mapping.
    @MainActor
    public init(selection: PostListItemSelection, postList: PostListModel?) {
        switch selection {
        case .new(let typeID):
            self = .new(typeID: typeID)
        case .existing(let item):
            self = .existing(postURL: item.id, descriptor: postList?.descriptor(for: item))
        }
    }
}

/// Builds the right `PostComposerModel` for a selection — the logic behind the iOS shell's
/// composer pane (`ComposerPane.load()`), split out so its draft-precedence rules are tested
/// without SwiftUI (#1968):
///
/// - A new composition restores only a genuinely-new draft of the same site + type; a queued
///   *update* to an existing post must never resume from the "New Post" entry point (#1370
///   review) — it surfaces when that post itself is reopened.
/// - Reopening an existing post prefers its own queued/pending edit over the server copy, so
///   the pending edit (and its waiting-for-network state) is discoverable through the natural
///   recovery path rather than hidden behind a fresh fetch (#1370 review). Only a pending edit
///   of the same type counts; otherwise the post is fetched.
@MainActor
public struct ComposerLoader {
    private let siteID: UUID
    private let registry: ContentTypeRegistry
    private let draftStore: ComposerDraftStore
    private let makeClient: () -> MicropubClient

    /// Creates a loader for one site session.
    ///
    /// - Parameters:
    ///   - siteID: The site's stable package UUID (keys the draft store).
    ///   - registry: Resolves `.new` type ids.
    ///   - draftStore: Where queued/restored drafts live.
    ///   - makeClient: The session's Micropub client factory (`MicropubSession.makeClient`).
    public init(
        siteID: UUID,
        registry: ContentTypeRegistry,
        draftStore: ComposerDraftStore,
        makeClient: @escaping () -> MicropubClient
    ) {
        self.siteID = siteID
        self.registry = registry
        self.draftStore = draftStore
        self.makeClient = makeClient
    }

    /// Opens `request`.
    ///
    /// - Parameter request: What to open.
    /// - Returns: The composer model, or the failure the pane should show.
    public func load(_ request: ComposerLoadRequest) async -> Result<PostComposerModel, ComposerLoadFailure> {
        switch request {
        case .new(let typeID):
            guard let descriptor = registry.descriptor(id: typeID) else {
                return .failure(.unavailableContentType)
            }
            return .success(PostComposerModel(
                descriptor: descriptor,
                siteID: siteID,
                client: makeClient(),
                draftStore: draftStore,
                restoringDraft: draftStore.loadNewDraft(forSite: siteID, typeID: typeID)
            ))
        case .existing(let postURL, let descriptor):
            guard let descriptor else {
                return .failure(.uneditablePostType)
            }
            if let pending = draftStore.loadDraft(forSite: siteID, postURL: postURL),
               pending.typeID == descriptor.id {
                return .success(PostComposerModel(
                    descriptor: descriptor,
                    siteID: siteID,
                    client: makeClient(),
                    draftStore: draftStore,
                    restoringDraft: pending
                ))
            }
            do {
                return .success(try await PostComposerModel.openExisting(
                    url: postURL,
                    descriptor: descriptor,
                    siteID: siteID,
                    client: makeClient(),
                    draftStore: draftStore
                ))
            } catch {
                return .failure(.postFetchFailed)
            }
        }
    }
}
