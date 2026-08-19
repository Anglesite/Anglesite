import Testing
import Foundation
@testable import AnglesiteCore

/// Exercises the composer's write-direction projection (#869) against every
/// `ContentTypeField.Kind`, and its round-trip through `MicropubContentSync`'s read direction —
/// the two halves that keep a phone-composed post and its git-synced file from diverging.
struct MicropubComposerProjectionTests {
    /// A synthetic descriptor declaring every field kind, each mapped to an mf2 property —
    /// broader than any single built-in type, so the per-kind matrix is exhaustive by
    /// construction rather than by whichever kinds the built-ins happen to use.
    private static let everyKind = ContentTypeDescriptor(
        id: "everyKind",
        displayName: "Every Kind",
        storage: .collection("mixed"),
        fields: [
            ContentTypeField("title", .string, required: true),
            ContentTypeField("lang", .language),
            ContentTypeField("summary", .text),
            ContentTypeField("body", .markdown, required: true),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("day", .date),
            ContentTypeField("flagged", .bool),
            ContentTypeField("link", .url),
            ContentTypeField("hero", .image),
            ContentTypeField("rating", .number),
            ContentTypeField("tags", .stringArray),
            ContentTypeField("photos", .imageArray),
            ContentTypeField(
                "jobs", .objectArray(fields: [ContentTypeField("role", .string)])),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "title": "p-name",
                "lang": "p-lang",
                "summary": "p-summary",
                "body": "e-content",
                "publishDate": "dt-published",
                "day": "dt-day",
                "flagged": "p-flagged",
                "link": "u-link",
                "hero": "u-hero",
                "rating": "p-rating",
                "tags": "p-category",
                "photos": "u-photo",
                "jobs": "p-jobs",
            ],
            schemaType: nil
        )
    )

    private static func filledValues() -> TypedContentEditor.Values {
        var values = TypedContentEditor.Values()
        values["title"] = .text("Hello World")
        values["lang"] = .text("fr")
        values["summary"] = .text("A summary")
        values["body"] = .text("It's — \"quoted\"\nline two\t✨ `code`")
        values["publishDate"] = .date(Date(timeIntervalSince1970: 1_721_558_400))
        values["day"] = .date(Date(timeIntervalSince1970: 1_721_520_000))   // midnight UTC
        values["flagged"] = .flag(true)
        values["link"] = .text("https://elsewhere.example/thing")
        values["hero"] = .text("https://owner.example/media/hero.jpg")
        values["rating"] = .number(4)
        values["tags"] = .list(["alpha", "beta"])
        values["photos"] = .list(["https://owner.example/media/a.jpg"])
        values["jobs"] = .records([["role": .text("Engineer")]])
        values["draft"] = .flag(false)
        return values
    }

    @Test("every mapped kind projects to its mf2 property; draft rides post-status")
    func projectsEveryKind() {
        let properties = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .draft)

        #expect(properties["name"] == [.string("Hello World")])
        #expect(properties["lang"] == [.string("fr")])
        #expect(properties["summary"] == [.string("A summary")])
        #expect(properties["content"] == [.string("It's — \"quoted\"\nline two\t✨ `code`")])
        #expect(properties["published"] == [.string("2024-07-21T10:40:00.000Z")])
        #expect(properties["day"] == [.string("2024-07-21")])
        #expect(properties["flagged"] == [.bool(true)])
        #expect(properties["link"] == [.string("https://elsewhere.example/thing")])
        #expect(properties["hero"] == [.string("https://owner.example/media/hero.jpg")])
        #expect(properties["rating"] == [.int(4)])
        #expect(properties["category"] == [.string("alpha"), .string("beta")])
        #expect(properties["photo"] == [.string("https://owner.example/media/a.jpg")])
        // objectArray has no wire form (no built-in collection type declares one; the read
        // direction doesn't reconstruct nested mf2 either) — omitted, not flattened.
        #expect(properties["jobs"] == nil)
        // draft's wire form is the Post Status extension's property, not an mf2 property.
        #expect(properties["draft"] == nil)
        #expect(properties["post-status"] == [.string("draft")])
    }

    @Test("an omitted visibility stamps no property at all; an explicit one is stamped")
    func visibilityOmittedUnlessExplicit() {
        // The default must OMIT, not default to public: this map is also an update's `replace`
        // map, and re-stamping a re-derived value would downgrade a post another client set to a
        // tier this enum doesn't model yet (`unlisted`/`private` both read back as `public`).
        let omitted = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .published)
        #expect(omitted["visibility"] == nil)
        #expect(omitted["post-status"] == [.string("published")])

        let explicitPublic = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .published, visibility: .public)
        #expect(explicitPublic["visibility"] == [.string("public")])

        let restricted = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .published, visibility: .contacts)
        #expect(restricted["visibility"] == [.string("contacts")])
    }

    @Test("a non-integral number projects as a JSON double")
    func nonIntegralNumber() {
        let encoded = MicropubComposerProjection.mf2Values(for: .number(4.5), kind: .number)
        #expect(encoded == [.double(4.5)])
    }

    @Test("empty and unset values are omitted, never sent as blank scalars")
    func emptyValuesOmitted() {
        var values = TypedContentEditor.Values()
        values["title"] = .text("Required Title")
        values["body"] = .text("Body")
        values["publishDate"] = .date(Date(timeIntervalSince1970: 1_721_558_400))
        values["summary"] = .text("")
        values["day"] = .date(nil)
        values["rating"] = .number(nil)
        values["tags"] = .list([])
        values["photos"] = .list(["", ""])   // blank rows a form's Add button left behind
        let properties = MicropubComposerProjection.properties(
            for: Self.everyKind, values: values, status: .published)

        #expect(properties["summary"] == nil)
        #expect(properties["day"] == nil)
        #expect(properties["rating"] == nil)
        #expect(properties["category"] == nil)
        #expect(properties["photo"] == nil)
        #expect(properties["post-status"] == [.string("published")])
    }

    @Test("mappedProperties lists every wire property except draft's")
    func mappedPropertiesListsWireForms() {
        let mapped = MicropubComposerProjection.mappedProperties(for: Self.everyKind)
        #expect(mapped == [
            "name", "lang", "summary", "content", "published", "day", "flagged", "link",
            "hero", "rating", "category", "photo", "jobs",
        ])
    }

    @Test("a composed post round-trips through the sync bridge's read direction")
    func roundTripsThroughSyncBridge() throws {
        let original = Self.filledValues()
        let properties = MicropubComposerProjection.properties(
            for: Self.everyKind, values: original, status: .draft)
        let decoded = try #require(MicropubContentSync.values(
            for: Self.everyKind, properties: properties,
            updatedAt: 0, slug: "hello-world"))

        for name in ["title", "lang", "summary", "body", "link", "hero"] {
            #expect(decoded[name] == original[name], "field \(name)")
        }
        #expect(decoded["publishDate"] == original["publishDate"])
        #expect(decoded["day"] == original["day"])
        #expect(decoded["rating"] == original["rating"])
        #expect(decoded["tags"] == original["tags"])
        #expect(decoded["photos"] == original["photos"])
        // post-status: draft → the draft flag, the sync bridge's special case.
        #expect(decoded["draft"] == .flag(true))
        // Documented one-way gaps, not silent drops: records have no wire form (decode
        // reconstructs the empty default), and a mapped bool decodes through the read
        // direction's defense-in-depth arm.
        #expect(decoded["jobs"] == .records([]))
        #expect(decoded["flagged"] == .flag(false))
    }

    @Test("the Markdown body survives the wire byte-identically")
    func bodySurvivesByteIdentically() throws {
        // The compose surface's parity contract (#869): the plain-text editor path never
        // transforms the body, so what was typed is what q=source hands back — including the
        // smart-quote bait, mixed line endings, and emoji a styled editor might normalize.
        let body = "It's — \"quoted\"\r\nline two\nreste à voir…\t✨ `code` \u{202F}thin"
        var values = TypedContentEditor.Values()
        values["title"] = .text("Parity")
        values["body"] = .text(body)
        values["publishDate"] = .date(Date(timeIntervalSince1970: 1_721_558_400))
        let properties = MicropubComposerProjection.properties(
            for: Self.everyKind, values: values, status: .draft)
        let decoded = try #require(MicropubContentSync.values(
            for: Self.everyKind, properties: properties, updatedAt: 0, slug: "parity"))
        let roundTripped = decoded["body"]
        #expect(roundTripped == .text(body))
    }
}
