import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel UTM codes (#1092)")
@MainActor
struct PlistEditorModelUTMCodesTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeModel(
        gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit
    ) throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelUTMCodesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir, gitCommit: gitCommit)
    }

    @Test("load() populates utmCampaigns from utm-codes.json, empty when absent")
    func loadPopulatesEmpty() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.utmCampaigns.isEmpty)
        #expect(model.isUTMCodesDirty == false)
    }

    @Test("isUTMCodesDirty flips true after appending a campaign, false after saveUTMCodes")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns.append(
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]))
        #expect(model.isUTMCodesDirty == true)
        let saved = await model.saveUTMCodes()
        #expect(saved == true)
        #expect(model.isUTMCodesDirty == false)
        #expect(try UTMCodesStore(sourceDirectory: model.sourceDirectory).load() == model.utmCampaigns)
    }

    @Test("saveUTMCodes normalizes appliesTo order on disk without touching the live in-memory order")
    func saveNormalizesOrderInMemoryAndOnDisk() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.notes, .blog])
        ]
        let saved = await model.saveUTMCodes()
        #expect(saved == true)
        #expect(model.utmCampaigns.first?.appliesTo == [.notes, .blog])
        #expect(model.isUTMCodesDirty == false)
        let loaded = try UTMCodesStore(sourceDirectory: model.sourceDirectory).load()
        #expect(loaded.first?.appliesTo == [.blog, .notes])
    }

    @Test("saveUTMCodes surfaces a validation failure via utmCodesError and leaves isUTMCodesDirty true")
    func saveValidationFailureSurfacesError() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        let saved = await model.saveUTMCodes()
        #expect(saved == false)
        #expect(model.utmCodesError != nil)
        #expect(model.isUTMCodesDirty == true)
    }

    @Test("saveUTMCodes clears a stale error once the owner reverts back to the saved state")
    func staleErrorClearedOnCleanShortCircuit() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        let firstSave = await model.saveUTMCodes()
        #expect(firstSave == false)
        #expect(model.utmCodesError != nil)

        // Revert back to the last saved (empty) state.
        model.utmCampaigns = model.savedUTMCampaigns
        #expect(model.isUTMCodesDirty == false)

        let secondSave = await model.saveUTMCodes()
        #expect(secondSave == true)
        #expect(model.utmCodesError == nil)
    }

    /// A saved utm-codes.json must land in git the same way any other content mutation does,
    /// rather than sitting as a silent uncommitted change (#1874).
    @Test("saveUTMCodes on success commits utm-codes.json to git")
    func saveCommitsToGit() async throws {
        let spy = PlistEditorUTMCodesCommitSpy()
        let model = try makeModel(gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })
        await model.load()
        model.utmCampaigns.append(
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]))

        let saved = await model.saveUTMCodes()

        #expect(saved == true)
        #expect(spy.paths() == ["utm-codes.json"])
        #expect(spy.messages() == ["anglesite: update utm-codes.json"])
    }

    /// A validation failure must never reach the git seam — nothing was written to disk to commit.
    @Test("saveUTMCodes on validation failure does not commit")
    func saveFailureSkipsCommit() async throws {
        let spy = PlistEditorUTMCodesCommitSpy()
        let model = try makeModel(gitCommit: { _, rel, msg in spy.record(rel, msg); return "deadbeef" })
        await model.load()
        model.utmCampaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]

        _ = await model.saveUTMCodes()

        #expect(spy.paths().isEmpty)
    }
}

/// Records the `(relPath, message)` pairs a model hands its injected `gitCommit`, matching the
/// spy-closure pattern `PageMetadataModelRobotsSettingsTests`/`SiteNavigatorModelTests` use for
/// this seam.
final class PlistEditorUTMCodesCommitSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String)] = []
    func record(_ rel: String, _ message: String) { lock.lock(); calls.append((rel, message)); lock.unlock() }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.0) }
    func messages() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.1) }
}
