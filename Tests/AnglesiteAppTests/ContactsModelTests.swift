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

    @Test("reload surfaces corruptFile when contacts.json fails to decode")
    func reloadSurfacesCorruptFile() async throws {
        let site = try Self.makeSite()
        try Data("{ not json".utf8).write(
            to: site.configDirectory.appendingPathComponent(ContactStore.filename))

        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: site)
        await model.reload()

        #expect(model.loadState == .corruptFile)
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

    @Test("accepting a promotion suggestion records the follower URL as linkedActor (#966 review)")
    func acceptPromotionSetsLinkedActor() async throws {
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

        let added = try #require(model.contacts.first)
        #expect(added.linkedActor == bob)
    }

    @Test("a manually-added contact leaves linkedActor nil")
    func manualAddLeavesLinkedActorNil() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")

        let added = try #require(model.contacts.first)
        #expect(added.linkedActor == nil)
    }

    @Test("configure(site:) resets per-site state so a window replay never leaks another site's contacts (#966 review)")
    func configureResetsStateAcrossSites() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        let firstSite = try Self.makeSite()
        model.configure(site: firstSite)
        await model.reload()
        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        #expect(model.contacts.count == 1)
        #expect(model.loadState == .loaded)

        // Simulate the same model instance being reused for a different site window (the
        // pattern `SiteWindowModel`'s cold-open path uses).
        let secondSite = try Self.makeSite()
        model.configure(site: secondSite)

        #expect(model.contacts.isEmpty)
        #expect(model.loadState == .idle)
        #expect(model.suggestions.isEmpty)
        #expect(model.scanFailure == nil)
        #expect(model.writeFailure == nil)
    }

    @Test("a write failure is surfaced via writeFailure rather than silently swallowed (#966 review)")
    func writeFailureIsSurfaced() async throws {
        // A regular file where `configDirectory` is expected forces the underlying
        // `ContactStore.write` to throw when it tries to create/write into it as a directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactsModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configAsFile = root.appendingPathComponent("Config")
        try Data().write(to: configAsFile)
        let site = CurrentSite(
            id: "site-1", packageURL: root, sourceDirectory: root, configDirectory: configAsFile)

        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: site)
        await model.reload()
        #expect(model.writeFailure == nil)

        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")

        #expect(model.writeFailure != nil)
        #expect(model.contacts.isEmpty)
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
