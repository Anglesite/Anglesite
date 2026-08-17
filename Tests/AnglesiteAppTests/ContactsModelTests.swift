import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("ContactsModel")
@MainActor
struct ContactsModelTests {
    private static func makeSite() throws -> CurrentSite {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactsModelTests-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        return CurrentSite(
            id: "site-1", packageURL: root, sourceDirectory: root, configDirectory: config)
    }

    private struct FakeContactsProvider: ContactsProviding {
        var result: Result<[MatchableContact], Error>
        func matchableContacts() async throws -> [MatchableContact] {
            try result.get()
        }
    }

    @Test("loads an empty list for a fresh site")
    func loadsEmptyForFreshSite() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: try Self.makeSite())
        await model.reload()

        #expect(model.loadState == .loaded)
        #expect(model.contacts.isEmpty)
    }

    @Test("add then remove round-trips through the store")
    func addAndRemove() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        #expect(model.contacts.count == 1)

        let added = try #require(model.contacts.first)
        await model.remove(added)
        #expect(model.contacts.isEmpty)
    }

    @Test("scanForMatches surfaces a promotion suggestion")
    func scanSurfacesPromotion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.scanForMatches(candidateFollowerURLs: [bob])

        #expect(model.suggestions.count == 1)
        #expect(model.scanFailure == nil)
    }

    @Test("scanForMatches surfaces permission denial without crashing")
    func scanSurfacesDenial() async throws {
        let provider = FakeContactsProvider(result: .failure(ContactsAccessError.denied))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.scanForMatches(candidateFollowerURLs: [])

        #expect(model.scanFailure == .permissionDenied)
        #expect(model.suggestions.isEmpty)
    }

    @Test("accepting a promotion suggestion adds it as a contact and clears the suggestion")
    func acceptPromotion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.scanForMatches(candidateFollowerURLs: [bob])
        let suggestion = try #require(model.suggestions.first)

        await model.accept(suggestion)

        #expect(model.contacts.contains { $0.me == bob && $0.displayName == "Bob Jones" })
        #expect(model.suggestions.isEmpty)
    }

    @Test("dismissing a suggestion removes it and it does not resurface until the next scan")
    func dismissSuggestion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.scanForMatches(candidateFollowerURLs: [bob])
        let suggestion = try #require(model.suggestions.first)

        model.dismiss(suggestion)
        #expect(model.suggestions.isEmpty)

        await model.scanForMatches(candidateFollowerURLs: [bob])
        #expect(model.suggestions.isEmpty)
    }
}
