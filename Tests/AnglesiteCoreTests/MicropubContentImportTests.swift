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
}
