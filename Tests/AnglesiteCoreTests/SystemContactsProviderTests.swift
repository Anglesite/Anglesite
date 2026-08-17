#if canImport(Contacts)
import Testing
import Foundation
import Contacts
@testable import AnglesiteCore

@Suite("SystemContactsProvider matching")
struct SystemContactsProviderTests {
    private static func makeContact(
        givenName: String,
        familyName: String = "",
        urlAddresses: [String] = [],
        socialProfileURLs: [String] = []
    ) -> CNContact {
        let mutable = CNMutableContact()
        mutable.givenName = givenName
        mutable.familyName = familyName
        mutable.urlAddresses = urlAddresses.map {
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0 as NSString)
        }
        mutable.socialProfiles = socialProfileURLs.map {
            // No `CNSocialProfileServiceMastodon` constant exists in this SDK (verified against
            // the actual Contacts.framework headers — only Facebook/Flickr/LinkedIn/MySpace/
            // SinaWeibo/TencentWeibo/Twitter/Yelp/GameCenter are predefined); the label is a
            // plain string and isn't read by `matchableContact(from:)` anyway, so use a literal.
            CNLabeledValue(
                label: "Mastodon",
                value: CNSocialProfile(
                    urlString: $0, username: nil, userIdentifier: nil, service: nil))
        }
        return mutable
    }

    @Test("extracts display name and URL addresses")
    func extractsNameAndURLs() {
        let contact = Self.makeContact(
            givenName: "Alice", familyName: "Smith",
            urlAddresses: ["https://alice.example"])

        let matchable = SystemContactsProvider.matchableContact(from: contact)

        #expect(matchable?.displayName == "Alice Smith")
        #expect(matchable?.urlAddresses == [URL(string: "https://alice.example")!])
    }

    @Test("extracts social profile URLs")
    func extractsSocialProfileURLs() {
        let contact = Self.makeContact(
            givenName: "Bob",
            socialProfileURLs: ["https://mastodon.social/users/bob"])

        let matchable = SystemContactsProvider.matchableContact(from: contact)

        #expect(matchable?.socialProfileURLs == [URL(string: "https://mastodon.social/users/bob")!])
    }

    @Test("returns nil for a contact with no name")
    func returnsNilForNoName() {
        let contact = Self.makeContact(givenName: "", urlAddresses: ["https://example.com"])
        #expect(SystemContactsProvider.matchableContact(from: contact) == nil)
    }

    @Test("returns nil for a contact with no URLs at all")
    func returnsNilForNoURLs() {
        let contact = Self.makeContact(givenName: "Carol")
        #expect(SystemContactsProvider.matchableContact(from: contact) == nil)
    }

    @Test("ignores an empty social profile URL string")
    func ignoresEmptySocialProfileURL() {
        let mutable = CNMutableContact()
        mutable.givenName = "Dana"
        mutable.socialProfiles = [
            CNLabeledValue(
                label: CNSocialProfileServiceTwitter,
                value: CNSocialProfile(
                    urlString: "", username: "dana", userIdentifier: nil, service: "Twitter"))
        ]
        #expect(SystemContactsProvider.matchableContact(from: mutable) == nil)
    }
}
#endif
