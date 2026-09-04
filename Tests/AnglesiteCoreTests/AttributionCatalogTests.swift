import Testing
import Foundation
@testable import AnglesiteCore

struct AttributionCatalogTests {
    @Test("decode round trips a fixture entry")
    func decodeRoundTripsAFixtureEntry() throws {
        let json = """
        [{"name":"swift-nio","version":"2.65.0","licenseSPDXId":"Apache-2.0","licenseText":"Apache License text…","homepage":"https://github.com/apple/swift-nio"}]
        """
        let entries = try AttributionCatalog.decode(Data(json.utf8), source: .appBinary)
        #expect(entries.count == 1)
        #expect(entries[0].name == "swift-nio")
        #expect(entries[0].licenseSPDXId == "Apache-2.0")
    }

    @Test("decode tolerates nil homepage and SPDX id")
    func decodeToleratesNilHomepageAndSPDXId() throws {
        let json = """
        [{"name":"some-fork","version":"abc1234","licenseSPDXId":null,"licenseText":"Custom license text.","homepage":null}]
        """
        let entries = try AttributionCatalog.decode(Data(json.utf8), source: .containerImage)
        #expect(entries.count == 1)
        #expect(entries[0].licenseSPDXId == nil)
        #expect(entries[0].homepage == nil)
    }

    @Test("decode throws decodingFailed on malformed JSON")
    func decodeThrowsDecodingFailedOnMalformedJSON() {
        #expect {
            try AttributionCatalog.decode(Data("not json".utf8), source: .websiteTemplate)
        } throws: { error in
            error as? AttributionCatalogError == .decodingFailed(.websiteTemplate)
        }
    }

    @Test("load throws resourceMissing when the bundle has no Attributions folder")
    func loadThrowsResourceMissingWhenBundleHasNoAttributionsFolder() {
        // Bundle.main inside `swift test` is the xctest runner, which has no
        // Resources/Attributions — same "missing bundled resource" shape TemplateRuntime
        // exercises for Resources/Template (TemplateRuntimeTests.resolveReportsMissingWhenNoSourceFound).
        #expect {
            try AttributionCatalog.load(.appBinary)
        } throws: { error in
            error as? AttributionCatalogError == .resourceMissing(.appBinary)
        }
    }

    /// Guards the checked-in manifests directly, independent of the generator scripts'
    /// correctness: every committed Resources/Attributions/*.json (that exists) must decode and
    /// be non-empty. Reads by repo-root-relative path (not `Bundle.main`) since the xctest host
    /// has no Attributions resources — same convention as
    /// `SiteScaffolderTests.realScaffoldScriptURL()`.
    @Test("every committed attributions manifest that exists decodes and is non-empty")
    func committedManifestsThatExistDecodeAndAreNonEmpty() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var checkedAtLeastOne = false
        for source in AttributionSource.allCases {
            let url = repoRoot.appendingPathComponent("Resources/Attributions/\(source.rawValue).json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let entries = try AttributionCatalog.decode(data, source: source)
            #expect(!entries.isEmpty, "\(source.rawValue).json decoded but is empty")
            checkedAtLeastOne = true
        }
        #expect(checkedAtLeastOne, "expected at least one Resources/Attributions/*.json to exist")
    }
}
