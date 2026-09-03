import SwiftUI
import AnglesiteCore

/// The Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderators, an approval
/// queue for pending join requests, members (with ban), banned members (with unban, #1742),
/// posts (with remove), and open reports (D5/#1438 — dismiss, or remove the reported target).
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
                if moderation.reports.isEmpty {
                    Text("No open reports.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.reports) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.target?.absoluteString ?? "Unknown target")
                            if let reason = report.reason, !reason.isEmpty {
                                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let reporter = report.reporter {
                                Text("Reported by \(reporter.absoluteString)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Spacer()
                                Button("Remove", role: .destructive) { moderation.removeReportTargetConfirmation = report }
                                    .disabled(report.target == nil)
                                Button("Dismiss") { Task { await moderation.dismissReport(report) } }
                            }
                        }
                    }
                }
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
        .confirmationDialog(
            "Remove the reported content?",
            isPresented: Binding(get: { moderation.removeReportTargetConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await moderation.confirmRemoveReportTarget() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { moderation.removeReportTargetConfirmation = nil }
        } message: {
            Text("This bans the reported member or removes the reported post, whichever was flagged. The report itself stays open until you dismiss it.")
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
