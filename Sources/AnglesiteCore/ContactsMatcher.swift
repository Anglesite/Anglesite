import Foundation

/// One system Contact's matchable identity signals — its display name plus every URL it carries
/// (website fields and social-profile URLs), already extracted from `CNContact` by whichever
/// `ContactsProviding` implementation supplied it (Task 3). Kept independent of
/// `Contacts.framework` types so this file, and its matching logic, stay portable and
/// unit-testable without `CNContactStore`.
public struct MatchableContact: Sendable, Equatable {
    public let displayName: String
    public let urlAddresses: [URL]
    public let socialProfileURLs: [URL]

    public init(displayName: String, urlAddresses: [URL], socialProfileURLs: [URL]) {
        self.displayName = displayName
        self.urlAddresses = urlAddresses
        self.socialProfileURLs = socialProfileURLs
    }
}

/// One suggested link between a system Contact and a known identity URL, surfaced in the
/// Contacts pane's "Find in Contacts…" scan (#966).
public struct MatchSuggestion: Sendable, Equatable {
    public let candidateURL: URL
    public let systemContactName: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        /// A manually-added contact's `me` URL matches a system contact whose name differs —
        /// offer to adopt the system contact's name.
        case enrichExisting(Contact)
        /// A not-yet-added follower's actor URL matches a system contact — offer to add them.
        case promoteToContact
    }

    public init(candidateURL: URL, systemContactName: String, kind: Kind) {
        self.candidateURL = candidateURL
        self.systemContactName = systemContactName
        self.kind = kind
    }
}

/// Pure matching logic (design doc §5) — no I/O, no `Contacts` import, so it runs the same in CI
/// as it does live: given a batch of system contacts and the app's own known identities, produce
/// suggestions in both directions.
public enum ContactsMatcher {
    public static func suggestions(
        matchableContacts: [MatchableContact],
        existingContacts: [Contact],
        candidateFollowerURLs: [URL]
    ) -> [MatchSuggestion] {
        var suggestions: [MatchSuggestion] = []

        for contact in existingContacts {
            guard let match = firstMatch(for: contact.me, in: matchableContacts) else { continue }
            guard match.displayName != contact.displayName else { continue }
            suggestions.append(
                MatchSuggestion(
                    candidateURL: contact.me, systemContactName: match.displayName,
                    kind: .enrichExisting(contact)))
        }

        let existingKeys = Set(existingContacts.map { normalizedIdentityKey(for: $0.me) })
        // `candidateFollowerURLs` can contain duplicates (a plausible shape from
        // `FollowersModel`'s paged, non-deduped remote data) — track keys already processed in
        // this loop so a repeated URL doesn't produce two identical `MatchSuggestion`s, which
        // `ContactsView`'s `ForEach(..., id: \.candidateURL)` would then render with duplicate
        // SwiftUI IDs.
        var seenKeys: Set<String> = []
        for followerURL in candidateFollowerURLs {
            let key = normalizedIdentityKey(for: followerURL)
            guard !existingKeys.contains(key) else { continue }
            guard seenKeys.insert(key).inserted else { continue }
            guard let match = firstMatch(for: followerURL, in: matchableContacts) else { continue }
            suggestions.append(
                MatchSuggestion(
                    candidateURL: followerURL, systemContactName: match.displayName,
                    kind: .promoteToContact))
        }

        return suggestions
    }

    private static func firstMatch(
        for url: URL, in matchableContacts: [MatchableContact]
    ) -> MatchableContact? {
        let key = normalizedIdentityKey(for: url)
        return matchableContacts.first {
            ($0.urlAddresses + $0.socialProfileURLs).contains {
                normalizedIdentityKey(for: $0) == key
            }
        }
    }
}
