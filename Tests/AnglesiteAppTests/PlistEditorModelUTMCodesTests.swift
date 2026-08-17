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

    private func makeModel() throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelUTMCodesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir)
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
}
