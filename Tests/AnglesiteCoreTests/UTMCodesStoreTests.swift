import Testing
import Foundation
@testable import AnglesiteCore

@Suite("UTMCodesStore")
struct UTMCodesStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UTMCodesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns an empty array, not a throw")
    func loadMissingReturnsEmpty() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        #expect(try store.load() == [])
    }

    @Test("save then load round-trips campaigns through utm-codes.json")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "affiliate-2026", appliesTo: [.blog, .notes]),
        ]
        try store.save(campaigns)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("utm-codes.json").path))
        #expect(try store.load() == campaigns)
    }

    @Test("save omits nil term/content from the written JSON")
    func omitsNilOptionalFields() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        try store.save([UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "x")])
        let raw = try String(contentsOf: dir.appendingPathComponent("utm-codes.json"), encoding: .utf8)
        #expect(!raw.contains("term"))
        #expect(!raw.contains("content"))
    }

    @Test("save normalizes appliesTo to canonical Target order regardless of input order")
    func normalizesTargetOrder() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "x", appliesTo: [.notes, .blog])
        try store.save([campaign])
        let loaded = try store.load()
        #expect(loaded.first?.appliesTo == [.blog, .notes])
    }

    @Test("save rejects two campaigns claiming the same target")
    func rejectsDuplicateTarget() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        #expect(throws: UTMCodesStore.ValidationError.duplicateTarget(.blog)) {
            try store.save(campaigns)
        }
    }

    @Test("save rejects an assigned campaign with an empty source")
    func rejectsMissingSourceOnAssignedCampaign() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "", medium: "feed", campaign: "a", appliesTo: [.blog])
        #expect(throws: UTMCodesStore.ValidationError.missingRequiredField(campaign.id, field: "source")) {
            try store.save([campaign])
        }
    }

    @Test("save accepts an incomplete draft campaign with no targets")
    func acceptsIncompleteDraftWithNoTargets() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "", medium: "", campaign: "")
        try store.save([campaign])
        #expect(try store.load() == [campaign])
    }

    @Test("a rejected save leaves the previously-saved file untouched")
    func rejectedSaveDoesNotOverwrite() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let good = [UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog])]
        try store.save(good)
        let bad = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        #expect(throws: (any Error).self) { try store.save(bad) }
        #expect(try store.load() == good)
    }

    @Test("Target.displayName covers every case with a non-empty label")
    func displayNameCoversEveryCase() {
        for target in UTMCodesStore.Target.allCases {
            #expect(!target.displayName.isEmpty)
        }
    }
}
