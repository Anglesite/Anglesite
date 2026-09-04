import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel redirects (#530)")
@MainActor
struct PlistEditorModelRedirectsTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    /// Builds a `PlistEditorModel` against a fresh temp `sourceDirectory` with a minimal
    /// `Info.plist` at `file.url` — `PlistEditorModel.load()` reads both the plist and (via this
    /// task) `redirects.json` from that same directory.
    private func makeModel(
        gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit
    ) throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelRedirectsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir, gitCommit: gitCommit)
    }

    @Test("load() populates redirectEntries from redirects.json, empty when absent")
    func loadPopulatesEmpty() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.redirectEntries.isEmpty)
        #expect(model.isRedirectsDirty == false)
    }

    @Test("isRedirectsDirty flips true after appending an entry, false after saveRedirects")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))
        #expect(model.isRedirectsDirty == true)
        let saved = await model.saveRedirects()
        #expect(saved == true)
        #expect(model.isRedirectsDirty == false)
        #expect(try RedirectsStore(sourceDirectory: model.sourceDirectory).load() == model.redirectEntries)
    }

    @Test("saveRedirects surfaces a validation failure via redirectsError and leaves isRedirectsDirty true")
    func saveValidationFailureSurfacesError() async throws {
        let model = try makeModel()
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent))
        let saved = await model.saveRedirects()
        #expect(saved == false)
        #expect(model.redirectsError != nil)
        #expect(model.isRedirectsDirty == true)
    }

    /// A saved redirects.json must land in git the same way any other content mutation does,
    /// rather than sitting as a silent uncommitted change (#1874).
    @Test("saveRedirects on success commits redirects.json to git")
    func saveCommitsToGit() async throws {
        let spy = PlistEditorRedirectsCommitSpy()
        let model = try makeModel(gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent))

        let saved = await model.saveRedirects()

        #expect(saved == true)
        #expect(spy.paths() == ["redirects.json"])
        #expect(spy.messages() == ["anglesite: update redirects.json"])
    }

    /// A validation failure must never reach the git seam — nothing was written to disk to commit.
    @Test("saveRedirects on validation failure does not commit")
    func saveFailureSkipsCommit() async throws {
        let spy = PlistEditorRedirectsCommitSpy()
        let model = try makeModel(gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })
        await model.load()
        model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent))

        _ = await model.saveRedirects()

        #expect(spy.paths().isEmpty)
    }
}

/// Records the `(relPath, message)` pairs a model hands its injected `gitCommit`, matching the
/// spy-closure pattern `PageMetadataModelRobotsSettingsTests`/`SiteNavigatorModelTests` use for
/// this seam.
final class PlistEditorRedirectsCommitSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String)] = []
    func record(_ rel: String, _ message: String) { lock.lock(); calls.append((rel, message)); lock.unlock() }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.0) }
    func messages() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.1) }
}
