import Foundation
import Observation
import AnglesiteCore

/// Drives the Contacts pane (Website ▸ Contacts…, #966): a per-site, private list of known
/// people, plus an opt-in Contacts.framework matching scan. App glue only — persistence and
/// matching logic live in `AnglesiteCore`.
@MainActor
@Observable
final class ContactsModel {
    enum LoadState: Equatable {
        case idle
        case loaded
        /// `ContactStore.load()` threw — the file exists but didn't decode. Surfaced rather than
        /// silently showing an empty list (see `ContactStore`'s doc comment for why).
        case corruptFile
    }

    enum ScanFailure: Equatable {
        case permissionDenied
        case other(String)
    }

    private(set) var contacts: [Contact] = []
    private(set) var loadState: LoadState = .idle
    private(set) var suggestions: [MatchSuggestion] = []
    private(set) var isScanning = false
    private(set) var scanFailure: ScanFailure?

    private var store: ContactStore?
    /// Session-scoped, like `FollowersModel.unreachableActors`: a dismissed suggestion can
    /// resurface on a later scan, which is fine since scans are always owner-initiated.
    private var dismissedSuggestionKeys: Set<String> = []
    private let contactsProvider: ContactsProviding

    init(contactsProvider: ContactsProviding = SystemContactsProvider()) {
        self.contactsProvider = contactsProvider
    }

    /// Records which site this pane reads. Called once per site open, like
    /// `FollowersModel.configure(site:)`. Does not load — `ContactsView`'s `.task` triggers
    /// ``reload()`` the same way `FollowersView`'s `.task` triggers `FollowersModel.load()`.
    func configure(site: CurrentSite) {
        store = ContactStore(configDirectory: site.configDirectory)
    }

    func reload() async {
        guard let store else { return }
        do {
            contacts = try await store.load()
            loadState = .loaded
        } catch {
            contacts = []
            loadState = .corruptFile
        }
    }

    func add(me: URL, displayName: String) async {
        guard let store else { return }
        let contact = Contact(me: me, displayName: displayName)
        try? await store.add(contact)
        await reload()
    }

    func update(_ contact: Contact) async {
        guard let store else { return }
        try? await store.update(contact)
        await reload()
    }

    func remove(_ contact: Contact) async {
        guard let store else { return }
        try? await store.remove(id: contact.id)
        await reload()
    }

    /// Runs one on-demand Contacts.framework scan (Website ▸ Contacts… ▸ "Find in Contacts…").
    /// `candidateFollowerURLs` are the not-yet-added follower actor IRIs to check for the
    /// promote-to-contact direction — the caller (`SiteWindowModel`) is responsible for making
    /// sure Followers has loaded before supplying them.
    func scanForMatches(candidateFollowerURLs: [URL]) async {
        isScanning = true
        scanFailure = nil
        defer { isScanning = false }
        do {
            let matchable = try await contactsProvider.matchableContacts()
            let fresh = ContactsMatcher.suggestions(
                matchableContacts: matchable,
                existingContacts: contacts,
                candidateFollowerURLs: candidateFollowerURLs)
            suggestions = fresh.filter { !dismissedSuggestionKeys.contains(suggestionKey($0)) }
        } catch ContactsAccessError.denied {
            scanFailure = .permissionDenied
        } catch {
            scanFailure = .other("\(error)")
        }
    }

    func dismiss(_ suggestion: MatchSuggestion) {
        dismissedSuggestionKeys.insert(suggestionKey(suggestion))
        suggestions.removeAll { suggestionKey($0) == suggestionKey(suggestion) }
    }

    func accept(_ suggestion: MatchSuggestion) async {
        switch suggestion.kind {
        case .enrichExisting(let contact):
            var updated = contact
            updated.displayName = suggestion.systemContactName
            await update(updated)
        case .promoteToContact:
            await add(me: suggestion.candidateURL, displayName: suggestion.systemContactName)
        }
        dismiss(suggestion)
    }

    private func suggestionKey(_ suggestion: MatchSuggestion) -> String {
        "\(suggestion.candidateURL.absoluteString)|\(suggestion.systemContactName)"
    }
}
