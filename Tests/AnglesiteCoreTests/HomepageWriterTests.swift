import Testing
import Foundation
@testable import AnglesiteCore

struct HomepageWriterTests {
    private let astro = """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout
      title="Welcome — Your New Anglesite Business Website"
      description="Your business website is ready to set up in Anglesite."
    >
      <h1>Welcome</h1>
      <p>This site is ready to customize in Anglesite. Open the app to edit your pages, add content, and publish when you're ready.</p>
    </BaseLayout>
    """

    @Test("fills the headline and blurb")
    func fillsHeadlineAndBlurb() {
        let out = HomepageWriter.fill(astro, headline: "Blue Bottle", blurb: "Neighborhood coffee in Oakland.", tagline: "Coffee, slow-roasted.")
        #expect(out.contains(#"title="Blue Bottle""#))
        #expect(out.contains(#"description="Neighborhood coffee in Oakland.""#))
        #expect(out.contains("<h1>Blue Bottle</h1>"))
        #expect(out.contains("<p>Neighborhood coffee in Oakland.</p>"))
        #expect(!out.contains("/start"))
    }

    @Test("an empty blurb leaves the intro default and uses tagline for the description")
    func emptyBlurbLeavesIntroDefaultAndUsesTaglineForDescription() {
        let out = HomepageWriter.fill(astro, headline: "Acme", blurb: "", tagline: "We do things.")
        #expect(out.contains(#"description="We do things.""#))
        #expect(out.contains("<h1>Acme</h1>"))
        // When no blurb is provided, the intro paragraph keeps the template default.
        #expect(out.contains("ready to customize in Anglesite"))
    }

    @Test("escapes attribute and markup characters")
    func escapesAttributeAndMarkup() {
        let out = HomepageWriter.fill(astro, headline: "Tom & \"Jerry\"", blurb: "1 < 2 & 3", tagline: "")
        #expect(out.contains(#"title="Tom &amp; &quot;Jerry&quot;""#))
        #expect(out.contains("<h1>Tom &amp; &quot;Jerry&quot;</h1>"))
        #expect(out.contains("<p>1 &lt; 2 &amp; 3</p>"))
    }

    // DRIFT GUARD: the real scaffolded index.astro must still contain the exact strings
    // HomepageWriter replaces. If the template changes them, fill() would silently no-op
    // and ship template copy instead of the owner's content.
    @Test("the real index.astro contains all sentinels")
    func realIndexAstroContainsAllSentinels() throws {
        let url = Self.realIndexAstroURL()
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains(HomepageWriter.titleLine), "titleLine sentinel drifted from template")
        #expect(src.contains(HomepageWriter.h1Line),    "h1Line sentinel drifted from template")
        #expect(src.contains(HomepageWriter.descLine),  "descLine sentinel drifted from template")
        #expect(src.contains(HomepageWriter.introLine), "introLine sentinel drifted from template")
    }

    // Injection coverage: markup-breaking chars in the headline must be escaped in the <h1>.
    @Test("a headline with angle brackets is escaped")
    func headlineWithAngleBracketsIsEscaped() {
        let astro = "<h1>Welcome</h1>"
        let out = HomepageWriter.fill(astro, headline: "</h1><script>", blurb: "", tagline: "")
        #expect(out.contains("<h1>&lt;/h1&gt;&lt;script&gt;</h1>"))
        #expect(!out.contains("<script>"))
    }

    /// Resolve the real index.astro from the in-repo template (Resources/Template/).
    static func realIndexAstroURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template/src/pages/index.astro")
    }
}
