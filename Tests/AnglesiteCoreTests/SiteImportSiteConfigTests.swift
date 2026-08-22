import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportSiteConfigTests {
    private func page(title: String?, excerpt: String? = nil, lang: String? = nil) -> CapturedPage {
        CapturedPage(
            url: "https://example.com/",
            extraction: ExtractionRecord(title: title, lang: lang, markdown: "body", excerpt: excerpt)
        )
    }

    // MARK: - seeds(fromHomepage:)

    @Test("seeds from a homepage page maps title, excerpt, and lang")
    func seedsFromHomepage() {
        let homepage = page(title: "My Site", excerpt: "A place for things", lang: "en")

        let seeds = ImportSiteConfig.seeds(fromHomepage: homepage)

        #expect(seeds.siteName == "My Site")
        #expect(seeds.tagline == "A place for things")
        #expect(seeds.lang == "en")
    }

    @Test("nil homepage produces all-nil seeds")
    func nilHomepageProducesNilSeeds() {
        let seeds = ImportSiteConfig.seeds(fromHomepage: nil)

        #expect(seeds.siteName == nil)
        #expect(seeds.tagline == nil)
        #expect(seeds.lang == nil)
    }

    @Test("a title-suffix delimiter strips everything after it, keeping the first segment")
    func titleSuffixIsStripped() {
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Hello — My Site")).siteName == "Hello")
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Hello – My Site")).siteName == "Hello")
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Hello | My Site")).siteName == "Hello")
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Hello - My Site")).siteName == "Hello")
        // No delimiter: the whole title is kept.
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Hello")).siteName == "Hello")
        // A bare hyphen inside a word (no surrounding spaces) is not a delimiter.
        #expect(ImportSiteConfig.seeds(fromHomepage: page(title: "Well-Known Site")).siteName == "Well-Known Site")
    }

    // MARK: - apply(_:toConfigText:)

    @Test("apply replaces an existing KEY=... line")
    func applyReplacesExistingLine() {
        let text = "ANGLESITE_VERSION=1.0.0\nSITE_NAME=\"Old Name\"\nDOMAIN=example.com\n"
        let seeds = SiteConfigSeeds(siteName: "New Name", tagline: nil, lang: nil)

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result == "ANGLESITE_VERSION=1.0.0\nSITE_NAME=\"New Name\"\nDOMAIN=example.com\n")
    }

    @Test("apply appends a missing key at the end")
    func applyAppendsMissingKey() {
        let text = "ANGLESITE_VERSION=1.0.0\n"
        let seeds = SiteConfigSeeds(siteName: "New Name", tagline: "A tagline", lang: "en")

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result == "ANGLESITE_VERSION=1.0.0\nSITE_NAME=\"New Name\"\nTAGLINE=\"A tagline\"\nLANG=\"en\"\n")
    }

    @Test("a commented #KEY= line counts as absent and is left alone; the key is appended")
    func commentedKeyLineIsLeftAloneAndAppended() {
        let text = "ANGLESITE_VERSION=1.0.0\n# SITE_NAME=example — the site's display name\n"
        let seeds = SiteConfigSeeds(siteName: "New Name", tagline: nil, lang: nil)

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result == """
        ANGLESITE_VERSION=1.0.0
        # SITE_NAME=example — the site's display name
        SITE_NAME="New Name"

        """)
    }

    @Test("apply escapes embedded double quotes in the value")
    func applyEscapesEmbeddedQuotes() {
        let text = ""
        let seeds = SiteConfigSeeds(siteName: "Say \"Hi\"", tagline: nil, lang: nil)

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result == "SITE_NAME=\"Say \\\"Hi\\\"\"\n")
    }

    @Test("apply is idempotent")
    func applyIsIdempotent() {
        let text = "ANGLESITE_VERSION=1.0.0\n# SECURITY_CONTACT=security@example.com\n"
        let seeds = SiteConfigSeeds(siteName: "New Name", tagline: "A tagline", lang: "en")

        let once = ImportSiteConfig.apply(seeds, toConfigText: text)
        let twice = ImportSiteConfig.apply(seeds, toConfigText: once)

        #expect(twice == once)
    }

    @Test("all-nil seeds leave the config text untouched")
    func nilSeedsLeaveTextUntouched() {
        let text = "ANGLESITE_VERSION=1.0.0\n# SITE_NAME=example\nDOMAIN=example.com\n"
        let seeds = SiteConfigSeeds(siteName: nil, tagline: nil, lang: nil)

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result == text)
    }

    @Test("apply preserves unrelated lines and comments byte-for-byte")
    func applyPreservesUnrelatedLines() {
        let text = """
        ANGLESITE_VERSION=1.0.0
        # SITE_URL=https://example.com        — site domain (used in feeds, sitemap, security.txt)
        # HSTS_PRELOAD=true                    — opt-in HSTS preload submission (hard to reverse)
        SITE_NAME="Old Name"
        """
        let seeds = SiteConfigSeeds(siteName: "New Name", tagline: nil, lang: nil)

        let result = ImportSiteConfig.apply(seeds, toConfigText: text)

        #expect(result.contains("# SITE_URL=https://example.com        — site domain (used in feeds, sitemap, security.txt)"))
        #expect(result.contains("# HSTS_PRELOAD=true                    — opt-in HSTS preload submission (hard to reverse)"))
        #expect(result.contains("SITE_NAME=\"New Name\""))
        #expect(!result.contains("Old Name"))
    }
}
