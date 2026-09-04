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

    /// Two-file fixture (sorted so `a-first` is always processed before `b-second`, matching
    /// `filesForImport`'s `.sorted { $0.path < $1.path }`) for the incremental-persistence tests
    /// below — a single-file fixture can't distinguish "written once at the end" from "written
    /// after each create."
    private func writeTwoFileFixture(siteDir: URL, configDir: URL) throws {
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/articles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        for (slug, title) in [("a-first", "First"), ("b-second", "Second")] {
            let post = """
            ---
            title: \(title)
            publishDate: 2026-01-01
            draft: false
            ---
            Body text.
            """
            try post.write(
                to: siteDir.appending(path: "src/content/articles/\(slug).md"),
                atomically: true, encoding: .utf8)
        }
    }

    @Test("persists sync state after each successful create, not only at the end of the loop")
    func persistsSyncStateIncrementally() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeTwoFileFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var stateSeenBeforeSecondCreate: MicropubContentCommitter.SyncState?
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                requestCount += 1
                if requestCount == 2 {
                    // The fix under test: the first file's `create` already returned above, and its
                    // sync-state entry must already be on disk by the time the *second* file's
                    // `create` fires — not deferred until the whole loop (both files) finishes.
                    stateSeenBeforeSecondCreate = MicropubContentCommitter.readSyncState(from: configDir)
                }
                let slug = requestCount == 1 ? "a-first" : "b-second"
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/\(slug)"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)

        #expect(imported == 2)
        let stateBefore = try #require(stateSeenBeforeSecondCreate)
        #expect(stateBefore.count == 1, "only the first file's entry should be on disk before the second create fires")
        #expect(stateBefore["https://owner.example/articles/a-first"] == "src/content/articles/a-first.md")

        let finalState = MicropubContentCommitter.readSyncState(from: configDir)
        #expect(finalState.count == 2)
    }

    @Test("a create failure partway through an import doesn't lose earlier successful creates' sync state")
    func retainsSyncStateAfterLaterFailure() async throws {
        // Simulates the crash/interrupt scenario the fix addresses: if the process had died right
        // here instead of the second `create` merely failing, the first file's sync-state entry
        // must already be safely on disk — otherwise the next run would re-`create` (and duplicate)
        // a post that already exists live.
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeTwoFileFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        struct SimulatedFailure: Error {}
        nonisolated(unsafe) var requestCount = 0
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                requestCount += 1
                guard requestCount == 1 else { throw SimulatedFailure() }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/a-first"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)

        #expect(imported == 1)
        let state = MicropubContentCommitter.readSyncState(from: configDir)
        #expect(state.count == 1)
        #expect(state["https://owner.example/articles/a-first"] == "src/content/articles/a-first.md")
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
        // entries), `.bool` (draft: true, the non-default branch), and the `.language`
        // default-fallback path (lang left unset in the fixture). `audience` (`.url`) is also set
        // here, but `article`'s `microformatProperties` has no entry for it at all (only
        // `title`/`summary`/`body`/`publishDate`/`updated`/`tags` are mapped —
        // `Sources/AnglesiteCore/Authoring/ContentTypeRegistry.swift`'s `article` descriptor), so it never
        // reaches the wire and both directions take the same omission branch `updated` would take
        // if unset: this field is along for the ride, not a genuine `.url` round-trip case. See
        // `importExportRoundTripsResolvedURL` below for that.
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

    @Test("import then export round-trips a resolved (non-omitted) .url field")
    func importExportRoundTripsResolvedURL() async throws {
        // `bookmark`'s `bookmarkOf` (`.url`, required) has a real `u-bookmark-of` mf2 mapping
        // (`ContentTypeRegistry.swift`'s `bookmark` descriptor), so unlike `article`'s `audience`
        // above, this genuinely exercises `values(for:)`'s "resolved from mf2" branch for `.url`
        // — the same `fieldValue(for:)` code path `.string`/`.text` already use, per
        // `MicropubContentSync.fieldValue`'s `case .string, .language, .text, .url, .image,
        // .markdown` arm — rather than the "no mapping, always omitted" branch.
        try await assertRoundTrips(
            collection: "bookmarks", slug: "great-article",
            contents: """
            ---
            bookmarkOf: https://example.com/a-great-article
            title: A Great Article
            publishDate: 2026-03-01
            tags:
              - reading
            ---
            Worth a read.
            """)
    }

    // MARK: - unsyncedFileCount (Finding, PR #1457 round 2 review)

    @Test("unsyncedFileCount reports 0 once every file is imported")
    func unsyncedFileCountReachesZeroAfterImport() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        #expect(
            MicropubContentImport.unsyncedFileCount(siteDirectory: siteDir, configDirectory: configDir) == 1,
            "the fixture's one file hasn't been imported yet")

        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/hello-world"])!
                return (Data(), response)
            })
        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)
        #expect(imported == 1)

        #expect(MicropubContentImport.unsyncedFileCount(siteDirectory: siteDir, configDirectory: configDir) == 0)
    }

    /// This is the case the PR #1457 round-2 review flagged: `importIfNeeded` catches and logs a
    /// per-file `client.create` failure rather than throwing, so a caller can't tell "nothing left
    /// to import" apart from "every file's create failed" purely from its `Int` return —
    /// `unsyncedFileCount` is the follow-up check that can.
    @Test("unsyncedFileCount stays non-zero when every create fails")
    func unsyncedFileCountStaysNonZeroAfterTotalFailure() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        struct SimulatedFailure: Error {}
        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { _ in throw SimulatedFailure() })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)
        #expect(imported == 0)

        #expect(
            MicropubContentImport.unsyncedFileCount(siteDirectory: siteDir, configDirectory: configDir) == 1,
            "the one file whose create failed must still count as pending")
    }

    @Test("unsyncedFileCount is 0 when there's nothing to import at all")
    func unsyncedFileCountZeroWithNoContent() {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        #expect(MicropubContentImport.unsyncedFileCount(siteDirectory: siteDir, configDirectory: configDir) == 0)
    }

    // MARK: - Unmapped-field warning (Finding 2, PR #1457 review)

    /// A synthetic `.collection`-storage type with two deliberately unmapped fields — `notes` has
    /// no `microformatProperties` entry at all, and `team` (`.objectArray`) has no wire form
    /// regardless of mapping (`MicropubComposerProjection.mf2Values` always returns `nil` for
    /// `.records`) — so importing an instance exercises both of `warnAboutUnmappedFields`'s gaps
    /// at once. None of the built-in `.collection`-stored descriptors have an unmapped or
    /// `.objectArray` field (only the `.singleton` `resume` type does, which import never walks),
    /// hence the synthetic registry rather than a built-in fixture.
    private static let widgetRegistry: ContentTypeRegistry = {
        let descriptor = ContentTypeDescriptor(
            id: "widget",
            displayName: "Widget",
            storage: .collection("widgets"),
            fields: [
                ContentTypeField("title", .string, required: true),
                ContentTypeField("notes", .text),
                ContentTypeField(
                    "team", .objectArray(fields: [
                        ContentTypeField("role", .string), ContentTypeField("name", .string),
                    ])),
                ContentTypeField("publishDate", .datetime, required: true),
                ContentTypeField("draft", .bool),
            ],
            projections: ContentTypeProjections(
                microformat: "h-entry",
                microformatProperties: [
                    "title": "p-name",
                    "publishDate": "dt-published",
                ],
                schemaType: nil
            )
        )
        return ContentTypeRegistry(types: [descriptor])
    }()

    @Test("logs a warning naming fields that will be silently dropped from the imported post")
    func warnsAboutUnmappedFieldsWithContent() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        // Unique per test run and embedded in the fixture's own relative path, so the log filter
        // below can't pick up another test's entry — `LogCenter.shared` is process-global and
        // Swift Testing runs suites in parallel, the same hazard `MicropubPostD1ClientTests`
        // documents (#977).
        let marker = "widget-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/widgets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let post = """
        ---
        title: A Widget
        notes: Some notes that have no wire mapping
        team:
          - role: Engineer
            name: Alex
        publishDate: 2026-01-01
        draft: false
        ---
        Body text.
        """
        try post.write(
            to: siteDir.appending(path: "src/content/widgets/\(marker).md"),
            atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/widgets/\(marker)"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client,
            registry: Self.widgetRegistry)

        #expect(imported == 1)

        let logged = await LogCenter.shared.snapshot().filter { $0.text.contains(marker) }
        #expect(logged.count == 1)
        let entry = try #require(logged.first)
        #expect(entry.source == "MicropubContentImport")
        #expect(entry.stream == .stderr)
        #expect(entry.text.contains("notes"))
        #expect(entry.text.contains("team"))
        // `title`/`publishDate` are mapped and non-empty, so they must not be reported as dropped.
        #expect(!entry.text.contains("title"))
        #expect(!entry.text.contains("publishDate"))
    }

    @Test("does not warn when every field either has a wire mapping or is empty")
    func noWarningWhenEverythingMapsOrIsEmpty() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let marker = "widget-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/widgets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        // `notes` and `team` are left unset (empty), so neither gap fires despite the descriptor
        // still lacking a wire mapping for them.
        let post = """
        ---
        title: A Widget
        publishDate: 2026-01-01
        draft: false
        ---
        Body text.
        """
        try post.write(
            to: siteDir.appending(path: "src/content/widgets/\(marker).md"),
            atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        let client = MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/widgets/\(marker)"])!
                return (Data(), response)
            })

        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client,
            registry: Self.widgetRegistry)

        #expect(imported == 1)
        let logged = await LogCenter.shared.snapshot().filter { $0.text.contains(marker) }
        #expect(logged.isEmpty)
    }
}
