import Testing
@testable import AnglesiteCore

struct ThirdPartyNoticeRendererTests {
    @Test("renders name, version, license, and homepage")
    func rendersNameVersionLicenseAndHomepage() {
        let attribution = OSSAttribution(
            name: "astro", version: "7.1.3", licenseSPDXId: "MIT",
            licenseText: "MIT License\n\nCopyright (c) …", homepage: "https://astro.build"
        )
        let markdown = ThirdPartyNoticeRenderer.render([attribution])
        #expect(markdown.contains("## astro 7.1.3"))
        #expect(markdown.contains("License: MIT"))
        #expect(markdown.contains("Homepage: https://astro.build"))
        #expect(markdown.contains("MIT License"))
    }

    @Test("omits missing fields gracefully")
    func omitsMissingFieldsGracefully() {
        let attribution = OSSAttribution(
            name: "some-fork", version: "abc123", licenseSPDXId: nil,
            licenseText: "Custom text.", homepage: nil
        )
        let markdown = ThirdPartyNoticeRenderer.render([attribution])
        #expect(!markdown.contains("License: "))
        #expect(!markdown.contains("Homepage: "))
        #expect(markdown.contains("Custom text."))
    }

    @Test("an empty list renders just the header")
    func emptyListRendersJustTheHeader() {
        let markdown = ThirdPartyNoticeRenderer.render([])
        #expect(markdown.hasPrefix("# Third-Party Notices"))
    }
}
