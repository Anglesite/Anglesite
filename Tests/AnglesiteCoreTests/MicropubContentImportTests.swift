import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct MicropubContentImportTests {
    /// `src/content/articles/` is used (not the brief sketch's `src/content/blog/`) because
    /// `blog` is the template's separate, untyped legacy collection
    /// (`Resources/Template/src/content.config.ts`) with no `ContentTypeDescriptor` — it has no
    /// mf2 projection to import through. `articles` is a real `ContentTypeRegistry` collection
    /// (the `article` descriptor) whose `title`/`publishDate`/`draft` fields match this fixture.
    private func writeFixture(siteDir: URL, configDir: URL) throws {
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/articles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let post = """
        ---
        title: Hello World
        publishDate: 2026-01-01
        draft: false
        ---
        Body text.
        """
        try post.write(
            to: siteDir.appending(path: "src/content/articles/hello-world.md"),
            atomically: true, encoding: .utf8)
    }

    @Test("imports a typed post file not yet in the sync map, and records its returned URL")
    func importsNewFile() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        var createdCount = 0
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                createdCount += 1
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/hello-world"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)

        #expect(imported == 1)
        #expect(createdCount == 1)
        let state = MicropubContentCommitter.readSyncState(from: configDir)
        #expect(state["https://owner.example/articles/hello-world"] == "src/content/articles/hello-world.md")
    }

    @Test("re-running is a no-op once every file is already in the sync map")
    func skipsAlreadyImported() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        try MicropubContentCommitter.writeSyncState(
            ["https://owner.example/articles/hello-world": "src/content/articles/hello-world.md"],
            to: configDir)

        var createdCount = 0
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                createdCount += 1
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/hello-world-2"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)

        #expect(imported == 0)
        #expect(createdCount == 0)
    }

    /// Decodes a Micropub create body's `properties` object (`{type, properties}`, the same
    /// shape `MicropubPost.decodePost` reads, though that helper is private to
    /// `MicropubClient.swift`) into the `[String: [JSONValue]]` map
    /// `MicropubContentSync.values(for:properties:updatedAt:slug:)` consumes.
    private func decodeProperties(from request: URLRequest) throws -> [String: [JSONValue]] {
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let rawProperties = try #require(json["properties"] as? [String: [Any]])
        var properties: [String: [JSONValue]] = [:]
        for (key, values) in rawProperties {
            properties[key] = values.compactMap(JSONValue.from)
        }
        return properties
    }

    /// Imports `contents` (a typed content file for `collection`/`descriptor`) through the real
    /// `MicropubContentImport.importIfNeeded` → `MicropubComposerProjection.properties(for:...)`
    /// path, captures the mf2 `properties` the fake transport received, maps them back through
    /// `MicropubContentSync.values(for:properties:updatedAt:slug:)`, and asserts the round trip
    /// is lossless.
    ///
    /// The comparison does NOT do a bare `reconstructed[field] == original[field]`:
    /// `values(for:)` deliberately OMITS a key (rather than setting a default) for a non-required
    /// date/url/number field with no resolvable mf2 value — see that function's doc comment.
    /// That's a documented merge/patch semantic for its real consumer,
    /// `MicropubContentCommitter.commit`, which feeds a `ResolvedPost.values` straight into
    /// `TypedContentEditor.write(post.values, into: baseContents, ...)`: an omitted key means
    /// "leave whatever's already in `baseContents` alone," not "this field is empty," so a
    /// locally-set value the mf2 wire form doesn't carry survives a pull. Comparing raw `Values`
    /// structs would misreport that documented omission as data loss (`.date(nil)`/`.text("")`
    /// present vs. absent). So this closes the loop the same way production code does — write the
    /// reconstructed values into the original file's own contents (mirroring `commit`'s
    /// `baseContents = existingContents ?? scaffold` for a file that already exists locally) and
    /// re-read — which is the actual, exercised round-trip path and the one that genuinely proves
    /// no data is lost or corrupted.
    private func assertRoundTrips(
        collection: String, slug: String, contents: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/\(collection)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fileURL = siteDir.appending(path: "src/content/\(collection)/\(slug).md")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        nonisolated(unsafe) var capturedRequest: URLRequest?
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                capturedRequest = request
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/\(collection)/\(slug)"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)
        #expect(imported == 1, sourceLocation: sourceLocation)

        let request = try #require(capturedRequest, sourceLocation: sourceLocation)
        let capturedProperties = try decodeProperties(from: request)

        let descriptor = try #require(
            ContentTypeRegistry.default.descriptor(forCollection: collection), sourceLocation: sourceLocation)
        let original = TypedContentEditor.read(contents, descriptor: descriptor)

        // `updatedAt` only feeds the `publishDate` fallback, and every fixture below sets its own
        // `publishDate` — present in `capturedProperties` — so an arbitrary value here shouldn't
        // affect the result.
        let reconstructed = try #require(
            MicropubContentSync.values(
                for: descriptor, properties: capturedProperties, updatedAt: 0, slug: slug),
            sourceLocation: sourceLocation)

        let rewritten = TypedContentEditor.write(reconstructed, into: contents, descriptor: descriptor)
        let reread = TypedContentEditor.read(rewritten, descriptor: descriptor)

        for field in descriptor.fields {
            let originalValue = original[field.name]
            let rereadValue = reread[field.name]
            #expect(
                rereadValue == originalValue,
                "field \(field.name) did not round-trip: original \(String(describing: originalValue)), reread \(String(describing: rereadValue))",
                sourceLocation: sourceLocation
            )
        }
    }

    @Test("import then export reconstructs equivalent field values (lossless round-trip)")
    func importExportRoundTrips() async throws {
        // Exercises `.string`/`.text`/`.markdown` (title/summary/body), `.datetime` with both a
        // set value (publishDate) and a set optional value (updated), `.stringArray` (tags, two
        // entries), `.url` (audience), `.bool` (draft: true, the non-default branch), and the
        // `.language` default-fallback path (lang left unset in the fixture).
        try await assertRoundTrips(
            collection: "articles", slug: "hello-world",
            contents: """
            ---
            title: Hello World
            summary: A quick recap of the trip
            publishDate: 2026-01-01T10:30:00.000Z
            updated: 2026-01-02T08:15:00.000Z
            tags:
              - swift
              - macos
            audience: https://example.com/audience
            draft: true
            ---
            Body text with **markdown**.
            """)
    }

    @Test("import then export round-trips a .number field (rating)")
    func importExportRoundTripsNumberField() async throws {
        // `review` is the only built-in descriptor with a `.number`-kind field (`rating`,
        // required) and has no `draft` field at all — covers both gaps `articles` above doesn't.
        try await assertRoundTrips(
            collection: "reviews", slug: "great-gatsby",
            contents: """
            ---
            itemReviewed: The Great Gatsby
            rating: 4
            publishDate: 2026-02-01
            ---
            Solid read, would recommend.
            """)
    }
}
