import SwiftUI
import AnglesiteCore

/// The Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderators, an approval
/// queue for pending join requests, members (with ban), banned members (with unban, #1742),
/// posts (with remove), and an inert reports placeholder (D5 — no report-handling exists
/// upstream yet).
struct ModerationView: View {
    @Bindable var moderation: ModerationModel
    /// Bound to the "Add Moderator" text field; cleared after a successful add.
    @State private var newModeratorIRI = ""

    var body: some View {
        List {
            Section("Moderators") {
                if moderation.moderators.isEmpty {
                    Text("Only you can moderate this community.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.moderators, id: \.self) { iri in
                        HStack {
                            Text(iri)
                            Spacer()
                            Button("Remove") { Task { await moderation.removeModerator(iri) } }
                        }
                    }
                }
                HStack {
                    TextField("Actor URL, e.g. https://example.social/users/alice", text: $newModeratorIRI)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addModerator)
                    Button("Add", action: addModerator)
                        .disabled(newModeratorIRI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Requests") {
                if moderation.pendingFollowers.isEmpty {
                    Text("No pending requests.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.pendingFollowers) { follower in
                        HStack {
                            Text(follower.actor.absoluteString)
                            Spacer()
                            Button("Approve") { Task { await moderation.approve(follower) } }
                        }
                    }
                }
            }
            Section("Members") {
                ForEach(moderation.members) { member in
                    HStack {
                        Text(member.name ?? member.actorURL.absoluteString)
                        Spacer()
                        Button("Ban", role: .destructive) { moderation.banConfirmation = member }
                    }
                }
            }
            Section("Banned") {
                if moderation.bannedMembers.isEmpty {
                    Text("No banned members.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.bannedMembers) { member in
                        HStack {
                            Text(member.name ?? member.actorURL.absoluteString)
                            Spacer()
                            Button("Unban") { Task { await moderation.unban(member) } }
                        }
                    }
                }
            }
            Section("Posts") {
                ForEach(moderation.posts) { post in
                    HStack {
                        Text(post.content ?? post.sourceURL.absoluteString).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) { moderation.removeConfirmation = post }
                    }
                }
            }
            Section("Reports") {
                Text("No report handling yet.").foregroundStyle(.secondary)
            }
        }
        .navigationSubtitle("Moderation")
        .alert("Error", isPresented: Binding(get: { moderation.errorMessage != nil }, set: { _ in moderation.errorMessage = nil })) {
            Button("OK") { moderation.errorMessage = nil }
        } message: {
            Text(moderation.errorMessage ?? "")
        }
        .confirmationDialog(
            "Ban this member?",
            isPresented: Binding(get: { moderation.banConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            // Action-default shape, matching every other destructive confirmation (#1736) — safe
            // now that ``ModerationModel/unban(_:)`` (#1742) gives a stray Return an in-app way
            // back, the same recovery path the other eight dialogs already had.
            Button("Ban", role: .destructive) { Task { await moderation.confirmBan() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { moderation.banConfirmation = nil }
        } message: {
            Text("This member's posts will stop appearing. Existing posts stay unless you also remove them.")
        }
        .confirmationDialog(
            "Remove this post?",
            isPresented: Binding(get: { moderation.removeConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await moderation.confirmRemove() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { moderation.removeConfirmation = nil }
        } message: {
            Text("This removes the post from the community timeline. The author's own copy on their own site is unaffected.")
        }
    }

    private func addModerator() {
        let iri = newModeratorIRI
        guard !iri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await moderation.addModerator(iri) {
                newModeratorIRI = ""
            }
        }
    }
}
