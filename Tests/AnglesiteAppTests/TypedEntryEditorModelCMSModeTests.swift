import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteAppCore
import AnglesiteCore
import AnglesiteIOS

/// Exercises `TypedEntryEditorModel.save()`'s CMS-mode branch (#800 Task A5): once the site's
/// composed Worker includes Micropub (`CMSModeStatus.isProvisioned`) and a session resolves,
/// saves route through `MicropubClient.create`/`.update` instead of file+git. The client is
/// injected via `makeMicropubClient`, so these tests touch neither the real Keychain nor the
/// network — same faked-seam style as `MicropubClientTests`/`StoredMicropubSessionsTests`.
@Suite(.serialized)
@MainActor
struct TypedEntryEditorModelCMSModeTests {
    private nonisolated static let endpoint = URL(string: "https://owner.example/micropub")!
    private static let entryContents = "---\npublishDate: 2026-01-01\n---\nBody.\n"

    private nonisolated static func response(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    /// Writes `settings.plist` (with the given `activeWorkerIDs`) and a `notes` entry file under
    /// fresh temp `configDir`/`sourceDir` directories, returning the pieces a `TypedEntryEditorModel`
    /// needs plus the entry's on-disk URL for later assertions.
    private func makeFixture(
        activeWorkerIDs: [String]?
    ) async throws -> (file: FileRef, descriptor: ContentTypeDescriptor, configDir: URL, sourceDir: URL, entryURL: URL) {
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sourceDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        var settings = SiteSettings()
        settings.activeWorkerIDs = activeWorkerIDs
        try await SiteConfigStore(configDirectory: configDir).save(settings)

        let entryURL = sourceDir.appendingPathComponent("src/content/notes/my-note.md")
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.entryContents.write(to: entryURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: entryURL, group: .posts, name: entryURL.lastPathComponent)
        let descriptor = try #require(ContentTypeRegistry().descriptor(id: "note"))
        return (file, descriptor, configDir, sourceDir, entryURL)
    }

    @Test("save() creates via MicropubClient when the site is CMS-mode provisioned and no prior URL is synced")
    func savesViaMicropubCreate() async throws {
        let (file, descriptor, configDir, sourceDir, entryURL) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        nonisolated(unsafe) var capturedRequest: URLRequest?
        let client = MicropubClient(
            endpoint: Self.endpoint, accessToken: "tok-123", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                capturedRequest = request
                return (Data(), Self.response(201, headers: ["Location": "https://owner.example/2026/my-note"]))
            }
        )
        nonisolated(unsafe) var factoryCalls: [(siteID: String, sourceDirectory: URL)] = []

        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { siteID, sourceDirectory in
                factoryCalls.append((siteID, sourceDirectory))
                return client
            }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(saved)
        #expect(factoryCalls.map(\.siteID) == ["site-1"])
        #expect(factoryCalls.map(\.sourceDirectory) == [sourceDir])

        let request = try #require(capturedRequest)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // A create body carries no "action" key (that's update's marker) and has the mf2 shape.
        #expect(json["action"] == nil)
        #expect(json["type"] as? [String] == ["h-entry"])
        let properties = try #require(json["properties"] as? [String: [Any]])
        #expect(properties["post-status"] as? [String] == ["draft"])

        // The returned URL is recorded against this file's Source/-relative path.
        let syncState = MicropubContentCommitter.readSyncState(from: configDir)
        #expect(syncState["https://owner.example/2026/my-note"] == "src/content/notes/my-note.md")

        // CMS-mode content saves never touch the local file — the read-side sync (Task A6/B1)
        // is what reconciles Source/ back to the CMS's copy.
        let onDisk = try String(contentsOf: entryURL, encoding: .utf8)
        #expect(onDisk == Self.entryContents)
    }

    /// #800 review, fix round 1: `client.create` already succeeded remotely by the time
    /// `writeSyncState` runs, so a failure persisting the local URL↔path bookkeeping must not
    /// fail the save — only the (best-effort) local record is at risk, not the user's edit.
    /// Forces that specific write to fail by pre-occupying `Config/micropubSync.json`'s path with
    /// a *directory* rather than injecting a fake filesystem: `settings.plist` (a different file
    /// in the same `configDir`) is unaffected, so the CMS-mode-provisioned check upstream of the
    /// write still passes, isolating the failure to exactly the write this test targets.
    @Test("save() still reports success when persisting the sync-state mapping fails after a successful create")
    func savesSucceedsEvenWhenSyncStateWriteFails() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        // Occupy micropubSync.json's path with a directory so `Data.write(to:options:.atomic)`
        // inside `writeSyncState` throws (can't atomically replace a directory with a file).
        try FileManager.default.createDirectory(
            at: configDir.appendingPathComponent("micropubSync.json"), withIntermediateDirectories: true)

        let client = MicropubClient(
            endpoint: Self.endpoint, accessToken: "tok-123", dpopKeyPair: DPoPKeyPair(),
            transport: { _ in
                (Data(), Self.response(201, headers: ["Location": "https://owner.example/2026/my-note"]))
            }
        )
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in client }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(saved, "the remote post already exists — a local bookkeeping-write failure must not fail the save")
        #expect(!model.isDirty, "the edit itself is considered saved even though the sync-state record was lost")
    }

    @Test("save() updates the synced post and deletes now-empty mapped properties")
    func savesViaMicropubUpdate() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let postURL = URL(string: "https://owner.example/2026/my-note")!
        try MicropubContentCommitter.writeSyncState(
            [postURL.absoluteString: "src/content/notes/my-note.md"], to: configDir)

        nonisolated(unsafe) var capturedRequest: URLRequest?
        let client = MicropubClient(
            endpoint: Self.endpoint, accessToken: "tok-123", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                capturedRequest = request
                return (Data(), Self.response(204))
            }
        )
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in client }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(saved)

        let request = try #require(capturedRequest)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "update")
        #expect(json["url"] as? String == postURL.absoluteString)
        // `tags` is mapped (bare mf2 name "category", the "p-" prefix stripped) but unset on this
        // fixture — deleted, not silently dropped. `body`/`publishDate` are set, so they're
        // `replace`d, not deleted; `lang`/`audience`/`draft` have no mf2 mapping at all.
        let deleted = try #require(json["delete"] as? [String])
        #expect(deleted == ["category"])

        // The sync-state mapping is untouched by an update (no new URL to record).
        let syncState = MicropubContentCommitter.readSyncState(from: configDir)
        #expect(syncState == [postURL.absoluteString: "src/content/notes/my-note.md"])
    }

    @Test("save() falls back to file+git when the site is not CMS-mode provisioned")
    func savesViaFileWhenUnprovisioned() async throws {
        let (file, descriptor, configDir, sourceDir, entryURL) = try await makeFixture(activeWorkerIDs: nil)
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        nonisolated(unsafe) var factoryCalled = false
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in
                factoryCalled = true
                return nil
            }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(saved)
        #expect(!factoryCalled, "an unprovisioned site must not even attempt to resolve a Micropub client")

        let onDiskContents = try String(contentsOf: entryURL, encoding: .utf8)
        let onDisk = TypedContentEditor.read(onDiskContents, descriptor: descriptor)
        #expect(onDisk["draft"] == .flag(true))
        #expect(MicropubContentCommitter.readSyncState(from: configDir).isEmpty)
    }

    @Test("save() falls back to file+git when no Micropub session is available yet")
    func savesViaFileWhenSessionUnavailable() async throws {
        let (file, descriptor, configDir, sourceDir, entryURL) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            // Provisioned, but no onboarded session — the factory itself reports "signed out".
            makeMicropubClient: { _, _ in nil }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(saved)
        let onDiskContents = try String(contentsOf: entryURL, encoding: .utf8)
        let onDisk = TypedContentEditor.read(onDiskContents, descriptor: descriptor)
        #expect(onDisk["draft"] == .flag(true))
    }

    /// #800 Task A6: `isCMSMode` mirrors `save()`'s own branch condition, computed once in `load()`
    /// (see its doc comment for why it can't be a plain computed `var`). `false` before `load()`
    /// runs — nothing has populated it yet — then flips to match provisioning after.
    @Test("isCMSMode reflects the site's CMS-mode provisioning after load()")
    func isCMSModeReflectsProvisioning() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in nil }
        )
        #expect(!model.isCMSMode, "isCMSMode is false before load() has populated it")
        await model.load()
        #expect(model.isCMSMode)
    }

    @Test("isCMSMode is false when the site isn't CMS-mode provisioned")
    func isCMSModeFalseWhenUnprovisioned() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: nil)
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in nil }
        )
        await model.load()
        #expect(!model.isCMSMode)
    }

    @Test("isCMSMode is false when the model has no configDirectory (no CMS-mode context)")
    func isCMSModeFalseWithNoConfigDirectory() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            gitCommit: { _, _, _ in "deadbeef" }
        )
        await model.load()
        #expect(!model.isCMSMode)
    }

    @Test("save() surfaces a distinct message when the Micropub session needs reauthorization")
    func saveSurfacesReauthorizationMessage() async throws {
        let (file, descriptor, configDir, sourceDir, _) = try await makeFixture(activeWorkerIDs: ["micropub"])
        defer {
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        let client = MicropubClient(
            endpoint: Self.endpoint, accessToken: "tok-123", dpopKeyPair: DPoPKeyPair(),
            transport: { _ in (Data(), Self.response(401)) }
        )
        let model = TypedEntryEditorModel(
            file: file, descriptor: descriptor, route: "/notes/my-note/", sourceDirectory: sourceDir,
            configDirectory: configDir, siteID: "site-1",
            gitCommit: { _, _, _ in "deadbeef" },
            makeMicropubClient: { _, _ in client }
        )
        await model.load()
        model.boolBinding("draft").wrappedValue = true

        let saved = await model.save()
        #expect(!saved)
        #expect(model.loadError?.localizedCaseInsensitiveContains("sign in") == true)
    }
}
