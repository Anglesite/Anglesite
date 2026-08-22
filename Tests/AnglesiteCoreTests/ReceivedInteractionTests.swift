// Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ReceivedInteraction")
struct ReceivedInteractionTests {
    @Test("round-trips through JSON encoding")
    func jsonRoundTrip() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: ReceivedInteraction.Author(
                name: "Jane Doe",
                url: URL(string: "https://other.example"),
                photo: URL(string: "https://other.example/photo.jpg")
            ),
            content: "Great post!",
            published: ISO8601DateFormatter().date(from: "2026-06-28T14:30:00Z")!,
            verified: ISO8601DateFormatter().date(from: "2026-06-28T14:35:12Z")!,
            verificationStatus: .verified
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded == interaction)
    }

    @Test("round-trips a vouch through JSON encoding")
    func vouchRoundTrips() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: nil,
            content: "Great post!",
            published: ISO8601DateFormatter().date(from: "2026-06-28T14:30:00Z")!,
            verified: ISO8601DateFormatter().date(from: "2026-06-28T14:35:12Z")!,
            verificationStatus: .verified,
            vouch: ReceivedInteraction.Vouch(url: URL(string: "https://trusted.example/")!, verified: true)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded == interaction)
        #expect(decoded.vouch?.verified == true)
    }

    @Test("vouch defaults to nil when not supplied")
    func vouchDefaultsToNil() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-no-vouch",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .mention,
            author: nil,
            content: nil,
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )
        #expect(interaction.vouch == nil)
    }

    @Test("interaction type maps to expected display categories")
    func interactionTypeCategories() {
        #expect(ReceivedInteraction.InteractionType.reply.isComment)
        #expect(ReceivedInteraction.InteractionType.like.isFacepile)
        #expect(ReceivedInteraction.InteractionType.repost.isFacepile)
        #expect(!ReceivedInteraction.InteractionType.mention.isComment)
        #expect(!ReceivedInteraction.InteractionType.mention.isFacepile)
    }

    @Test("bluesky is a valid protocol type and round-trips through JSON")
    func blueskyProtocolTypeRoundTrips() throws {
        let interaction = try ReceivedInteraction(
            id: "bsky-abc123",
            type: .bluesky,
            source: URL(string: "https://bsky.app/profile/alice.bsky.social/post/abc123")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: nil,
            content: "hello",
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded.type == .bluesky)
    }

    @Test("gitPath produces the expected file path")
    func gitPath() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://example.com")!,
            target: URL(string: "https://my.site/post")!,
            interactionType: .mention,
            author: nil,
            content: nil,
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )
        #expect(interaction.gitPath == "data/interactions/wm-abc123.json")
    }

    @Test("rejects IDs containing path-traversal sequences")
    func rejectsPathTraversal() {
        #expect(throws: ReceivedInteraction.ValidationError.self) {
            try ReceivedInteraction(
                id: "../../etc/passwd",
                type: .webmention,
                source: URL(string: "https://example.com")!,
                target: URL(string: "https://my.site/post")!,
                interactionType: .mention,
                author: nil,
                content: nil,
                published: Date(),
                verified: Date(),
                verificationStatus: .verified
            )
        }
    }
}
