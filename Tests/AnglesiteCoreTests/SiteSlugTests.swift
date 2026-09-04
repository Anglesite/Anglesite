import Testing
import Foundation
@testable import AnglesiteCore

struct SiteSlugTests {
    @Test("lowercases and hyphenates")
    func lowercasesAndHyphenates() {
        #expect(SiteSlug.derive(from: "Blue Bottle Cafe") == "blue-bottle-cafe")
    }
    @Test("strips punctuation and collapses hyphens")
    func stripsPunctuationAndCollapsesHyphens() {
        #expect(SiteSlug.derive(from: "  Hello!!   World  ") == "hello-world")
    }
    @Test("folds diacritics")
    func foldsDiacritics() {
        #expect(SiteSlug.derive(from: "Café Niño") == "cafe-nino")
    }
    @Test("empty falls back to untitled")
    func emptyFallsBackToUntitled() {
        #expect(SiteSlug.derive(from: "   ") == "untitled-site")
    }
    @Test("draft defaults headline from name")
    func draftDefaultsHeadlineFromName() {
        let d = NewSiteDraft(siteType: .business, name: "Acme")
        #expect(d.headline == "Acme")
        #expect(d.themeID == "")
    }
    @Test("a digits-only name is kept")
    func digitsOnlyNameIsKept() {
        #expect(SiteSlug.derive(from: "42") == "42")
    }
    @Test("a transliterated name is an ASCII slug and non-empty")
    func transliteratedNameIsAsciiSlugAndNonEmpty() {
        // Accented / ligature names should transliterate to a clean ascii slug, not collapse to empty.
        let slug = SiteSlug.derive(from: "Æsop & Çödë")
        #expect(!slug.isEmpty)
        #expect(slug == slug.lowercased())
        // Only lowercase ascii alphanumerics and hyphens, no leading/trailing hyphen.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        #expect(slug.unicodeScalars.allSatisfy { allowed.contains($0) }, "unexpected chars in \(slug)")
        #expect(!slug.hasPrefix("-"))
        #expect(!slug.hasSuffix("-"))
    }
}
