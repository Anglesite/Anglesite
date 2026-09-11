import Foundation
import AnglesiteIOS

/// What the composer column shows: a fresh composition of a type, or an existing post.
public enum PostListItemSelection: Hashable, Sendable {
    /// A new post of the registry type `typeID`.
    case new(typeID: String)
    /// An existing post from the list.
    case existing(PostListModel.Item)
}

extension PersistedSelection {
    /// The portable form worth persisting (#1436): an existing post's URL rather than its whole
    /// `PostListModel.Item`, since only the URL survives a relaunch — the item itself is
    /// re-resolved once the post list reloads.
    ///
    /// - Parameter selection: The in-memory selection to persist.
    public init(_ selection: PostListItemSelection) {
        switch selection {
        case .new(let typeID):
            self = .new(typeID: typeID)
        case .existing(let item):
            self = .existing(postURL: item.id)
        }
    }
}
