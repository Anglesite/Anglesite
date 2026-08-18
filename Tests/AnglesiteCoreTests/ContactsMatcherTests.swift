import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContactsMatcher")
struct ContactsMatcherTests {
    private static let aliceMe = URL(string: "https://alice.example")!
    private static let bobActor = URL(string: "https://mastodon.social/users/bob")!

    @Test("suggests enriching an existing contact whose name differs from the system contact")
    func suggestsEnrichment() {
        let existing = Contact(me: Self.aliceMe, displayName: "alice.example")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [Self.aliceMe], socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.systemContactName == "Alice Smith")
        #expect(suggestions.first?.kind == .enrichExisting(existing))
    }

    @Test("does not suggest enrichment when the names already match")
    func skipsEnrichmentWhenNamesMatch() {
        let existing = Contact(me: Self.aliceMe, displayName: "Alice Smith")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [Self.aliceMe], socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.isEmpty)
    }

    @Test("suggests promoting a not-yet-added follower that matches a system contact")
    func suggestsPromotion() {
        let systemContacts = [
            MatchableContact(
                displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [Self.bobActor])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [],
            candidateFollowerURLs: [Self.bobActor])

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.systemContactName == "Bob Jones")
        #expect(suggestions.first?.kind == .promoteToContact)
    }

    @Test("does not suggest promoting a follower already added as a contact")
    func skipsPromotionForExistingContact() {
        let existing = Contact(me: Self.bobActor, displayName: "Bob Jones")
        let systemContacts = [
            MatchableContact(
                displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [Self.bobActor])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [Self.bobActor])

        #expect(suggestions.isEmpty)
    }

    @Test("matches URLs that differ only by scheme and trailing slash")
    func matchesNormalizedURLs() {
        let existing = Contact(me: URL(string: "http://alice.example/")!, displayName: "alice")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [URL(string: "https://alice.example")!],
                socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.count == 1)
    }

    @Test("deduplicates repeated follower URLs into a single promotion suggestion (#966 review)")
    func dedupesDuplicateFollowerURLs() {
        let systemContacts = [
            MatchableContact(
                displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [Self.bobActor])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [],
            candidateFollowerURLs: [Self.bobActor, Self.bobActor])

        #expect(suggestions.count == 1)
    }

    @Test("produces no suggestions when nothing matches")
    func noMatches() {
        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: [], existingContacts: [], candidateFollowerURLs: [Self.bobActor])
        #expect(suggestions.isEmpty)
    }
}
