import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteAppCore
import AnglesiteCore

/// Exercises the two pieces of `MicropubSiteConnectSheet`'s content-import trigger (Task 8/B2)
/// that don't require hosting the view: the manual "Import Content" button's visibility rule,
/// and the cancellation-aware completion-persisting helper. `MicropubContentImport.importIfNeeded`
/// itself is covered by `MicropubContentImportTests` in `AnglesiteCoreTests`.
@Suite(.serialized)
struct MicropubSiteConnectSheetTests {
    // MARK: - shouldShowManualImportButton

    @Test(
        "the manual import button shows whenever contentImportCompleted isn't explicitly true",
        arguments: [
            (nil, true),       // never loaded / never run — show it
            (false, true),     // explicitly not completed — show it
            (true, false),     // completed — hide it
        ] as [(Bool?, Bool)]
    )
    func manualImportButtonVisibility(contentImportCompleted: Bool?, expected: Bool) {
        #expect(
            MicropubSiteConnectSheet.shouldShowManualImportButton(contentImportCompleted: contentImportCompleted)
                == expected)
    }

    // MARK: - runImportAndPersistCompletion

    /// Mirrors `MicropubContentImportTests.writeFixture` — a single typed `article` post ready
    /// to import, plus the `Config/` directory `runImportAndPersistCompletion` writes
    /// `settings.plist` into.
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

    private func fakeClient(created: @escaping @Sendable () -> Void) -> MicropubClient {
        MicropubClient(
            endpoint: URL(string: "https://owner.example/micropub")!,
            accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { request in
                created()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "https://owner.example/articles/hello-world"])!
                return (Data(), response)
            })
    }

    @Test("persists contentImportCompleted when the calling task was not cancelled")
    func persistsCompletionWhenNotCancelled() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        let imported = await MicropubSiteConnectSheet.runImportAndPersistCompletion(
            siteDirectory: siteDir, configDirectory: configDir, client: fakeClient(created: {}),
            isCancelled: { false })

        #expect(imported == 1)
        let settings = try await SiteConfigStore(configDirectory: configDir).load()
        #expect(settings.contentImportCompleted == true)
    }

    @Test("does not persist contentImportCompleted when the calling task was cancelled")
    func skipsPersistingCompletionWhenCancelled() async throws {
        let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try writeFixture(siteDir: siteDir, configDir: configDir)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        // The import itself still runs to completion — `MicropubContentImport.importIfNeeded`
        // isn't cancellation-aware — only the completion-flag write is skipped.
        let imported = await MicropubSiteConnectSheet.runImportAndPersistCompletion(
            siteDirectory: siteDir, configDirectory: configDir, client: fakeClient(created: {}),
            isCancelled: { true })

        #expect(imported == 1)
        let settings = try await SiteConfigStore(configDirectory: configDir).load()
        #expect(settings.contentImportCompleted == nil)
    }
}
