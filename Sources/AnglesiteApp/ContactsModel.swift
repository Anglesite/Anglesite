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
    /// Set when `add`/`update`/`remove`'s underlying `ContactStore` write throws (disk-full,
    /// `Config/` permission errors) — design doc §3 calls these out as direct user actions that
    /// expect feedback, unlike a background scan failure. Cleared on the next successful write.
    private(set) var writeFailure: String?

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
    ///
    /// Also resets every piece of per-site state: `ContactsModel` instances are reused across a
    /// site-window replay (`SiteWindowModel`'s cold-open path calls `contacts.configure(site:)`
    /// unconditionally), and without this reset the previous site's contacts/suggestions would
    /// stay visible — briefly showing one site's private contact list under another site's
    /// window — until `reload()` completed. Resetting `loadState` to `.idle` is sufficient to
    /// trigger a fresh load: `ContactsView`'s `.task` only calls `reload()` when idle.
    func configure(site: CurrentSite) {
        store = ContactStore(configDirectory: site.configDirectory)
        contacts = []
        loadState = .idle
        suggestions = []
        scanFailure = nil
        writeFailure = nil
        dismissedSuggestionKeys = []
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

    /// `linkedActor` records the ActivityPub actor IRI when `me` came from a follower promotion
    /// (see `accept(_:)`'s `.promoteToContact` case) — `nil` for a manually-added contact, which
    /// is why the "Add Contact…" sheet's call site relies on this parameter's default.
    func add(me: URL, displayName: String, linkedActor: URL? = nil) async {
        guard let store else { return }
        let contact = Contact(me: me, displayName: displayName, linkedActor: linkedActor)
        do {
            try await store.add(contact)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
        await reload()
    }

    func update(_ contact: Contact) async {
        guard let store else { return }
        do {
            try await store.update(contact)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
        await reload()
    }

    func remove(_ contact: Contact) async {
        guard let store else { return }
        do {
            try await store.remove(id: contact.id)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
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
            // The candidate URL IS the follower's actor IRI on this path (promotion candidates
            // come from `SiteWindowModel.candidateFollowerURLsForContactsMatching()`, which maps
            // `FollowersModel.rows.map(\.actor)`), so it doubles as both the best-available `me`
            // identity and the recorded `linkedActor`.
            await add(
                me: suggestion.candidateURL, displayName: suggestion.systemContactName,
                linkedActor: suggestion.candidateURL)
        }
        dismiss(suggestion)
    }

    private func suggestionKey(_ suggestion: MatchSuggestion) -> String {
        "\(suggestion.candidateURL.absoluteString)|\(suggestion.systemContactName)"
    }
}
