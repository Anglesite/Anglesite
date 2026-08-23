import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportSummaryModelTests {
    @Test("countLines includes non-zero counts in fixed order: blog, pages, notes, photos, bookmarks, replies, likes, images")
    func countLinesOrder() {
        let plan = ImportPlan(
            counts: ["likes": 1, "blog": 42, "pages": 6, "bookmarks": 2, "notes": 3, "photos": 5, "replies": 1],
            imageCount: 310,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.countLines == [
            "42 blog posts",
            "6 pages",
            "3 notes",
            "5 photos",
            "2 bookmarks",
            "1 reply",
            "1 like",
            "310 images"
        ])
    }

    @Test("countLines omits zero counts")
    func countLinesOmitsZeros() {
        let plan = ImportPlan(
            counts: ["blog": 5, "pages": 0, "notes": 3],
            imageCount: 0,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.countLines == ["5 blog posts", "3 notes"])
    }

    @Test("countLines handles singular forms correctly")
    func countLinesSingular() {
        let plan = ImportPlan(
            counts: ["blog": 1, "pages": 1, "notes": 1, "photos": 1, "bookmarks": 1, "replies": 1, "likes": 1],
            imageCount: 1,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.countLines == [
            "1 blog post",
            "1 page",
            "1 note",
            "1 photo",
            "1 bookmark",
            "1 reply",
            "1 like",
            "1 image"
        ])
    }

    @Test("countLines includes images from imageCount even when not in counts")
    func countLinesIncludesImages() {
        let plan = ImportPlan(
            counts: ["blog": 2],
            imageCount: 15,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.countLines == ["2 blog posts", "15 images"])
    }

    @Test("attentionLine is nil when problems is empty")
    func attentionLineNilWhenNoProblems() {
        let plan = ImportPlan(
            counts: ["blog": 5],
            imageCount: 0,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.attentionLine == nil)
    }

    @Test("attentionLine describes problems with correct singular/plural")
    func attentionLineWithProblems() {
        let plan1 = ImportPlan(
            counts: ["pages": 5, "blog": 2],
            imageCount: 0,
            problems: [ImportProblem(sourceURL: "https://e.com/1", message: "boom")],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model1 = ImportSummaryModel(plan: plan1)
        #expect(model1.attentionLine == "1 page couldn't be brought over cleanly")

        let plan3 = ImportPlan(
            counts: ["pages": 5, "blog": 2],
            imageCount: 0,
            problems: [
                ImportProblem(sourceURL: "https://e.com/1", message: "boom"),
                ImportProblem(sourceURL: "https://e.com/2", message: "boom"),
                ImportProblem(sourceURL: "https://e.com/3", message: "boom")
            ],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model3 = ImportSummaryModel(plan: plan3)
        #expect(model3.attentionLine == "3 pages couldn't be brought over cleanly")
    }

    @Test("skippedLine is nil when skippedURLs is empty")
    func skippedLineNilWhenEmpty() {
        let plan = ImportPlan(
            counts: ["blog": 5],
            imageCount: 0,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        #expect(model.skippedLine == nil)
    }

    @Test("skippedLine describes skipped URLs with correct singular/plural")
    func skippedLineWithURLs() {
        let plan1 = ImportPlan(
            counts: ["blog": 5],
            imageCount: 0,
            problems: [],
            skippedURLs: ["https://e.com/tag/x"],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model1 = ImportSummaryModel(plan: plan1)
        #expect(model1.skippedLine == "1 archive page was left behind (tags, categories)")

        let plan12 = ImportPlan(
            counts: ["blog": 5],
            imageCount: 0,
            problems: [],
            skippedURLs: ["https://e.com/tag/x", "https://e.com/category/y", "https://e.com/author/z",
                          "https://e.com/page/2", "https://e.com/search", "https://e.com/feed",
                          "https://e.com/tag/a", "https://e.com/category/b", "https://e.com/author/c",
                          "https://e.com/page/3", "https://e.com/search/q", "https://e.com/feed/2"],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model12 = ImportSummaryModel(plan: plan12)
        #expect(model12.skippedLine == "12 archive pages were left behind (tags, categories)")
    }

    @Test("model is Equatable")
    func modelEquatable() {
        let plan = ImportPlan(
            counts: ["blog": 5],
            imageCount: 10,
            problems: [ImportProblem(sourceURL: "https://e.com/1", message: "boom")],
            skippedURLs: ["https://e.com/tag/x"],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model1 = ImportSummaryModel(plan: plan)
        let model2 = ImportSummaryModel(plan: plan)

        #expect(model1 == model2)
    }

    @Test("model is Sendable")
    func modelSendable() async {
        let plan = ImportPlan(
            counts: ["blog": 5],
            imageCount: 10,
            problems: [],
            skippedURLs: [],
            rungBreakdown: [:],
            seeds: SiteConfigSeeds(siteName: "Site")
        )
        let model = ImportSummaryModel(plan: plan)

        await Task { @Sendable in
            _ = model
        }.value
    }
}
