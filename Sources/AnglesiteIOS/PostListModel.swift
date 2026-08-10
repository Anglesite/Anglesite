// Sources/AnglesiteIOS/PostListModel.swift
import Foundation
import SwiftUI
import AnglesiteCore

/// Drives the iOS shell's post list (#869): browses a site's posts — published and draft alike —
/// via the Micropub `q=source` list extension (design §6's deliberate choice over the public
/// feed, which by definition never shows drafts). Requires the site's IndieAuth session, same as
/// editing; there is no unauthenticated browse path.
@MainActor
@Observable
public final class PostListModel {
    /// One row: a post resolved to enough to list and open it.
    public struct Item: Identifiable, Hashable, Sendable {
        /// The post's canonical URL — its identity everywhere in the Micropub model.
        public let id: URL
        /// The row's title: the post's `name`, or its content's first line for title-less notes.
        public let title: String
        /// The post's collection, parsed from its URL's first path segment (never re-derived
        /// from mf2 — classification happened Worker-side at create time). `nil` for a post
        /// whose URL doesn't have the `{collection}/{slug}` shape.
        public let collection: String?
        /// Whether the post is a draft (the Post Status extension's `post-status`).
        public let isDraft: Bool
    }

    /// The list's loading state.
    public enum State: Equatable {
        case loading
        /// The token was rejected — route to IndieAuth re-auth (#868).
        case authRequired
        /// The fetch failed; carries a short description and the rows from the last good fetch
        /// (empty on first load) so a refresh failure doesn't blank an already-shown list.
        case failed(String, previous: [Item])
        case posts([Item])
    }

    /// Current state — see ``State``.
    public private(set) var state: State = .loading

    private let client: MicropubClient
    private let registry: ContentTypeRegistry
    /// Generation guard for overlapping refreshes, same pattern as `SitePickerModel`.
    private var refreshGeneration: UInt64 = 0

    /// Creates a list over `client`'s site.
    ///
    /// - Parameters:
    ///   - client: The site's Micropub client (from the ``MicropubSession``).
    ///   - registry: Resolves each post's collection to its content type.
    public init(client: MicropubClient, registry: ContentTypeRegistry = .default) {
        self.client = client
        self.registry = registry
    }

    /// The rows currently showable, regardless of state (previous rows during a failed refresh).
    public var items: [Item] {
        switch state {
        case .posts(let items): return items
        case .failed(_, let previous): return previous
        case .loading, .authRequired: return []
        }
    }

    /// Rows filtered to one content type's collection, for the shell's per-type lists.
    ///
    /// - Parameter collection: The collection name to filter by; `nil` returns everything.
    /// - Returns: The matching rows, server order (newest first).
    public func items(inCollection collection: String?) -> [Item] {
        guard let collection else { return items }
        return items.filter { $0.collection == collection }
    }

    /// Re-fetches the list. Safe to call repeatedly (initial `.task`, pull-to-refresh, and
    /// after the composer returns); overlapping calls are ordered by generation, latest wins.
    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if case .authRequired = state { state = .loading }
        do {
            let posts = try await client.listPosts()
            guard generation == refreshGeneration else { return }
            state = .posts(posts.compactMap(Self.item(for:)))
        } catch let error as MicropubError {
            guard generation == refreshGeneration else { return }
            if error.requiresReauthorization {
                state = .authRequired
            } else {
                state = .failed(Self.describe(error), previous: items)
            }
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed(error.localizedDescription, previous: items)
        }
    }

    /// Maps one listed post to a row; `nil` for an item without the canonical URL every list
    /// item is contracted to carry (nothing to open, nothing to identify the row by).
    static func item(for post: MicropubPost) -> Item? {
        guard let url = post.url else { return nil }
        let title = post.firstString("name")
            ?? post.firstString("content").map(Self.firstLine)
            ?? url.lastPathComponent
        let collection = MicropubContentSync.collectionAndSlug(from: url.absoluteString)
            .map(\.collection)
        return Item(
            id: url,
            title: title,
            collection: collection,
            isDraft: post.status == .draft
        )
    }

    /// The content type for a row, resolved through the registry's collection lookup.
    ///
    /// - Parameter item: The row to resolve.
    /// - Returns: The descriptor, or `nil` when the collection isn't a registered type.
    public func descriptor(for item: Item) -> ContentTypeDescriptor? {
        item.collection.flatMap { registry.descriptor(forCollection: $0) }
    }

    private static func firstLine(_ content: String) -> String {
        let line = content.split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init) ?? content
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func describe(_ error: MicropubError) -> String {
        switch error {
        case .unreachable:
            return "Your site can't be reached right now."
        case .serverError(let status, _):
            return "Your site's server had trouble (HTTP \(status))."
        case .requestFailed(let status, _):
            return "The site declined the request (HTTP \(status))."
        case .decodingFailed:
            return "The site's response wasn't understood."
        case .unauthorized, .mediaEndpointNotConfigured, .dpopUnavailable:
            return "The request failed."
        }
    }
}
