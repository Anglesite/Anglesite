import SwiftUI
import AppKit
import AnglesiteCore

/// Main-pane Contacts surface (Website ▸ Contacts…, #966): the site's private list of known
/// people, with an opt-in "Find in Contacts…" scan. Mirrors `FollowersView`'s wiring shape.
struct ContactsView: View {
    @Bindable var contacts: ContactsModel
    /// Not-yet-added follower actor IRIs to check during a scan. Async because the caller
    /// (`SiteWindowModel`) may need to load Followers first — see
    /// `SiteWindowModel.candidateFollowerURLsForContactsMatching()`.
    let candidateFollowerURLs: () async -> [URL]

    @State private var isPresentingAddSheet = false
    @State private var editingContact: Contact?

    var body: some View {
        Group {
            switch contacts.loadState {
            case .idle:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .corruptFile:
                corruptFileMessage
            case .loaded:
                loadedContent
            }
        }
        .navigationSubtitle("Contacts")
        .task { if contacts.loadState == .idle { await contacts.reload() } }
        .sheet(isPresented: $isPresentingAddSheet) {
            ContactEditSheet(title: "Add Contact", meText: "", displayName: "") { me, displayName in
                await contacts.add(me: me, displayName: displayName)
            }
        }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(
                title: "Edit Contact", meText: contact.me.absoluteString,
                displayName: contact.displayName
            ) { me, displayName in
                var updated = contact
                updated.me = me
                updated.displayName = displayName
                await contacts.update(updated)
            }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(contacts.contacts.count) contacts").font(.headline)
                Spacer()
                Button("Find in Contacts…") {
                    Task {
                        let candidates = await candidateFollowerURLs()
                        await contacts.scanForMatches(candidateFollowerURLs: candidates)
                    }
                }
                .disabled(contacts.isScanning)
                Button("Add Contact…") { isPresentingAddSheet = true }
            }
            .padding()

            if let failure = contacts.scanFailure {
                scanFailureBanner(failure)
            }

            if !contacts.suggestions.isEmpty {
                suggestionsSection
            }

            if contacts.contacts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(contacts.contacts) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestions").font(.subheadline).foregroundStyle(.secondary)
            ForEach(contacts.suggestions, id: \.candidateURL) { suggestion in
                suggestionRow(suggestion)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: MatchSuggestion) -> some View {
        HStack {
            // `systemContactName` is Contacts-framework-supplied, and `candidateURL` is a
            // follower/contact-supplied identity — both rendered verbatim via string
            // interpolation into a plain `Text`, never as a localization key.
            switch suggestion.kind {
            case .enrichExisting:
                Text(
                    "Use “\(suggestion.systemContactName)” from Contacts for "
                        + "\(suggestion.candidateURL.host ?? suggestion.candidateURL.absoluteString)?")
            case .promoteToContact:
                Text("“\(suggestion.systemContactName)” matches a follower — add as a contact?")
            }
            Spacer()
            Button("Add") { Task { await contacts.accept(suggestion) } }
            Button("Dismiss") { contacts.dismiss(suggestion) }
        }
    }

    @ViewBuilder
    private func scanFailureBanner(_ failure: ContactsModel.ScanFailure) -> some View {
        HStack {
            switch failure {
            case .permissionDenied:
                Text("Contacts access wasn't granted.")
                Button("Open System Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .other(let reason):
                Text("Couldn't scan Contacts").foregroundStyle(.secondary)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No contacts yet").font(.title2)
            Text(
                "Add people you know by their website address, or scan Contacts to find people "
                    + "you already follow."
            )
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var corruptFileMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't read your contacts").font(.title2)
            Text(
                "The contacts file may be damaged. Back it up, then remove Config/contacts.json "
                    + "to start fresh."
            )
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).font(.headline)
                Text(contact.me.absoluteString).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            linkageBadges(for: contact)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingContact = contact }
        .contextMenu {
            Button("Edit…") { editingContact = contact }
            Button("Delete", role: .destructive) { Task { await contacts.remove(contact) } }
        }
    }

    /// Small icon badges showing which identities this contact is linked to (design doc §4).
    /// Purely informational — editing the linkage itself is out of scope (design doc §9).
    @ViewBuilder
    private func linkageBadges(for contact: Contact) -> some View {
        HStack(spacing: 4) {
            if contact.linkedActor != nil {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .help("Linked to a Fediverse follower")
            }
            if contact.linkedFeed != nil {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(.secondary)
                    .help("Linked to a followed feed")
            }
        }
        .font(.caption)
    }
}

/// Add/edit sheet shared by both flows in `ContactsView` — `title` and the initial field values
/// are the only difference between "Add Contact" and "Edit Contact".
private struct ContactEditSheet: View {
    let title: String
    @State var meText: String
    @State var displayName: String
    let onSave: (URL, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $displayName)
            TextField("Website (e.g. https://example.com)", text: $meText)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private func save() {
        switch ContactEditValidation.validate(displayName: displayName, meText: meText) {
        case .failure(let message):
            validationError = message
        case .success(let validated):
            Task {
                await onSave(validated.url, validated.displayName)
                dismiss()
            }
        }
    }
}

/// `Result`'s `Failure` generic parameter requires `Error` conformance, but
/// `ContactEditValidation.validate(displayName:meText:)` returns its failure message as a plain
/// `String` (it's UI text for `ContactEditSheet`, never thrown) — this narrow, file-local
/// conformance is what makes `Result<_, String>` compile.
extension String: Error {}

/// Pure validation for `ContactEditSheet`'s Save action, pulled out of the view so it can be
/// unit-tested directly — see this task's test strategy note above. Not `private`, for the same
/// testability reason `FollowerAvatar.dimensionsWithinBound(_:)` isn't.
enum ContactEditValidation {
    /// `.success` carries the trimmed name and parsed URL ready to hand to `onSave`; `.failure`
    /// carries the message `ContactEditSheet` shows under the fields.
    static func validate(
        displayName: String, meText: String
    ) -> Result<(url: URL, displayName: String), String> {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure("Enter a name.")
        }
        let trimmedURLText = meText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURLText),
            url.scheme == "http" || url.scheme == "https"
        else {
            return .failure("Enter a valid http(s) website address.")
        }
        return .success((url, trimmedName))
    }
}
