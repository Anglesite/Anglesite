import Testing
import Foundation
@testable import AnglesiteCore

struct OSSAttributionTests {
    @Test("id combines name and version")
    func identityCombinesNameAndVersion() {
        let attribution = OSSAttribution(
            name: "swift-nio", version: "2.65.0", licenseSPDXId: "Apache-2.0",
            licenseText: "Apache License", homepage: "https://github.com/apple/swift-nio"
        )
        #expect(attribution.id == "swift-nio@2.65.0")
    }

    @Test("codable round trips")
    func codableRoundTrips() throws {
        let original = OSSAttribution(
            name: "SwiftGit2", version: "abc1234", licenseSPDXId: nil,
            licenseText: "Custom license text.", homepage: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OSSAttribution.self, from: data)
        #expect(decoded == original)
    }

    @Test("AttributionSource raw values match manifest file stems")
    func attributionSourceRawValuesMatchManifestFileStems() {
        #expect(AttributionSource.appBinary.rawValue == "app-binary")
        #expect(AttributionSource.containerImage.rawValue == "container-image")
        #expect(AttributionSource.websiteTemplate.rawValue == "website-template")
        #expect(AttributionSource.emdashSite.rawValue == "emdash-site")
    }

    @Test("display names")
    func displayNames() {
        #expect(AttributionSource.appBinary.displayName == "App")
        #expect(AttributionSource.containerImage.displayName == "Container & Sidecar")
        #expect(AttributionSource.websiteTemplate.displayName == "Website Template")
        #expect(AttributionSource.emdashSite.displayName == "EmDash Site Template")
    }

    /// #2088: an EmDash site installs the overlay's lockfile, not the template's, so its notice
    /// must come from the overlay's set.
    @Test("siteTemplate(for:) picks the overlay's set for an EmDash site only")
    func siteTemplateForKind() {
        #expect(AttributionSource.siteTemplate(for: .emdash) == .emdashSite)
        #expect(AttributionSource.siteTemplate(for: .anglesite) == .websiteTemplate)
        #expect(AttributionSource.siteTemplate(for: .unrecognized("x")) == .websiteTemplate)
    }
}
