import Foundation
#if canImport(Contacts)
import Contacts
#endif

/// One system contact's matchable identity signals, plus how to fetch a batch of them. The
/// `Contacts.framework`-backed implementation lives behind `#if canImport(Contacts)` — mirrors
/// `FoundationModelAssistant`'s platform-guarded-framework-inside-a-portable-target pattern — so
/// this protocol itself stays usable from portable code and from tests without ever touching
/// `CNContactStore`.
public protocol ContactsProviding: Sendable {
    /// Requests Contacts access if needed, then returns every system contact's matchable URLs.
    /// Throws ``ContactsAccessError/denied`` if the owner declines the permission prompt.
    func matchableContacts() async throws -> [MatchableContact]
}

public enum ContactsAccessError: Error, Equatable, Sendable {
    case denied
}

#if canImport(Contacts)
/// The real, `CNContactStore`-backed provider. Requests access on first use — never at launch —
/// per the design doc §5's "opt-in per scan" requirement.
public struct SystemContactsProvider: ContactsProviding {
    public init() {}

    public func matchableContacts() async throws -> [MatchableContact] {
        let store = CNContactStore()
        let granted = try await requestAccess(store: store)
        guard granted else { throw ContactsAccessError.denied }
        return try await Task.detached(priority: .utility) {
            try Self.fetchAll(store: store)
        }.value
    }

    private func requestAccess(store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Runs off the calling task (see the `Task.detached` above) because `enumerateContacts`
    /// blocks synchronously over the whole address book.
    private static func fetchAll(store: CNContactStore) throws -> [MatchableContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [MatchableContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            if let matchable = matchableContact(from: contact) {
                results.append(matchable)
            }
        }
        return results
    }

    /// Maps one `CNContact` to its matchable identity signals, or `nil` if it has neither a
    /// usable name nor any URL to match against. Pure — no store access, no I/O — so it's
    /// pulled out of `fetchAll` specifically to be unit-tested directly (see this task's test
    /// strategy note above and `SystemContactsProviderTests`). Not `private`, for the same
    /// testability reason `FollowerAvatar.dimensionsWithinBound(_:)` isn't.
    static func matchableContact(from contact: CNContact) -> MatchableContact? {
        // `CNContact.organizationName` is non-optional (empty string when unset) on this SDK, so
        // `??` against it can't be used directly — fall back to it explicitly instead.
        let formattedName = CNContactFormatter.string(from: contact, style: .fullName)
        let name = (formattedName?.isEmpty == false) ? formattedName! : contact.organizationName
        guard !name.isEmpty else { return nil }
        let urls = contact.urlAddresses.compactMap { URL(string: $0.value as String) }
        let socialURLs = contact.socialProfiles.compactMap { labeled -> URL? in
            let urlString = labeled.value.urlString
            return urlString.isEmpty ? nil : URL(string: urlString)
        }
        guard !urls.isEmpty || !socialURLs.isEmpty else { return nil }
        return MatchableContact(displayName: name, urlAddresses: urls, socialProfileURLs: socialURLs)
    }
}
#endif
