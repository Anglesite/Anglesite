import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportPlanTests {
    private func item(url: String, rung: ImportItem.Rung, images: [String] = []) -> ImportItem {
        ImportItem(sourceURL: url, title: "T", markdown: "m", images: images, rung: rung, hint: .none)
    }

    @Test("counts and rungBreakdown built from mixed destinations and rungs")
    func countsAndRungBreakdown() {
        let classified = [
            ClassifiedItem(item: item(url: "https://e.com/1", rung: .wpREST, images: ["a.png", "b.png"]),
                           destination: .collection(name: "blog", slug: "1")),
            ClassifiedItem(item: item(url: "https://e.com/2", rung: .wpREST),
                           destination: .collection(name: "blog", slug: "2")),
            ClassifiedItem(item: item(url: "https://e.com/3", rung: .feed, images: ["c.png"]),
                           destination: .collection(name: "notes", slug: "3")),
            ClassifiedItem(item: item(url: "https://e.com/about", rung: .readability),
                           destination: .page(route: "/about")),
            ClassifiedItem(item: item(url: "https://e.com/contact", rung: .microformats),
                           destination: .page(route: "/contact")),
        ]
        let resolved = ResolvedContent(items: [], homepage: nil, skippedURLs: ["https://e.com/tag/x"],
                                       problems: [ImportProblem(sourceURL: "https://e.com/broken", message: "boom")])
        let seeds = SiteConfigSeeds(siteName: "Site", tagline: "Tag", lang: "en")

        let plan = ImportPlanBuilder.plan(resolved: resolved, classified: classified, seeds: seeds)

        #expect(plan.counts == ["blog": 2, "notes": 1, "pages": 2])
        #expect(plan.imageCount == 3)
        #expect(plan.rungBreakdown == ["wp-rest": 2, "feed": 1, "readability": 1, "microformats": 1])
        #expect(plan.problems == resolved.problems)
        #expect(plan.skippedURLs == resolved.skippedURLs)
        #expect(plan.seeds == seeds)
    }

    @Test("report save/load round-trips through import-report.json")
    func reportSaveLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteImportPlanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = ImportPlan(counts: ["blog": 1], imageCount: 1,
                              problems: [ImportProblem(sourceURL: "https://e.com/x", message: "m")],
                              skippedURLs: ["https://e.com/tag/x"], rungBreakdown: ["wp-rest": 1],
                              seeds: SiteConfigSeeds(siteName: "Site"))
        let report = ImportReport(plan: plan, writtenPaths: ["blog/1/index.md"],
                                  installedImagePaths: ["images/a.png"],
                                  redirects: [RedirectEntry(source: "/old", destination: "/blog/1/", code: 301)],
                                  writeProblems: [])

        try report.save(to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ImportReport.fileName).path))
        let loaded = try ImportReport.load(from: dir)
        #expect(loaded == report)
    }
}
