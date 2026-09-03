// Sources/AnglesiteMobile/PostListScreen.swift
import SwiftUI
import AnglesiteIOS
import AnglesiteCore

/// The middle column (#869): a site's posts — drafts included — from the Micropub `q=source`
/// list, optionally filtered to one content type. Selection drives the composer column.
struct PostListScreen: View {
    let model: PostListModel
    /// The collection to filter by (`nil` = every post).
    let collection: String?
    @Binding var selection: PostListItemSelection?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading posts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .authRequired:
                ContentUnavailableView {
                    Label("Sign In Needed", systemImage: "person.badge.key")
                } description: {
                    Text("Your site needs you to sign in again before your posts can be shown.")
                }
            case .failed(let message, previous: let previous) where previous.isEmpty:
                ContentUnavailableView {
                    Label("Couldn't Load Posts", systemImage: "wifi.slash")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                }
            case .posts, .failed:
                list
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private var rows: [PostListModel.Item] { model.items(inCollection: collection) }

    private var list: some View {
        List(selection: $selection) {
            if case .failed(let message, _) = model.state {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(rows) { item in
                NavigationLink(value: PostListItemSelection.existing(item)) {
                    HStack {
                        Text(verbatim: item.title)
                            .lineLimit(2)
                        Spacer()
                        if item.isDraft {
                            Text("Draft")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Posts Yet", systemImage: "square.and.pencil")
                } description: {
                    Text("Posts you create appear here, drafts included.")
                }
            }
        }
    }
}

/// What the composer column shows: a fresh composition of a type, or an existing post.
enum PostListItemSelection: Hashable {
    case new(typeID: String)
    case existing(PostListModel.Item)
}

extension PersistedSelection {
    /// The portable form worth persisting (#1436): an existing post's URL rather than its whole
    /// `PostListModel.Item`, since only the URL survives a relaunch — the item itself is
    /// re-resolved once the post list reloads.
    init(_ selection: PostListItemSelection) {
        switch selection {
        case .new(let typeID):
            self = .new(typeID: typeID)
        case .existing(let item):
            self = .existing(postURL: item.id)
        }
    }
}
