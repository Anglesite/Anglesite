import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportClassifierTests {
    private func item(url: String, hint: ImportItem.Hint, title: String? = "T") -> ImportItem {
        ImportItem(sourceURL: url, title: title, markdown: "m", rung: .readability, hint: hint)
    }

    @Test(arguments: [
        ("https://e.com/2024/05/01/hi", ImportItem.Hint.wpPost, ImportDestination.collection(name: "blog", slug: "hi")),
        ("https://e.com/about", .wpPage, .page(route: "/about")),
        ("https://e.com/b-1", .bookmark(of: "https://x.com/p"), .collection(name: "bookmarks", slug: "b-1")),
        ("https://e.com/n-1", .note, .collection(name: "notes", slug: "n-1")),
        ("https://e.com/blog/heuristic-post", .none, .collection(name: "blog", slug: "heuristic-post")),
        ("https://e.com/contact", .none, .page(route: "/contact")),
    ])
    func classifies(_ url: String, _ hint: ImportItem.Hint, _ expected: ImportDestination) {
        let resolved = ResolvedContent(items: [item(url: url, hint: hint)],
                                       homepage: nil, skippedURLs: [], problems: [])
        let classified = ContentClassifier.classify(resolved, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(classified.first?.destination == expected)
    }

    @Test("deterministic slug from URL with empty last segment")
    func deterministicSlugFromURL() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let url = "https://e.com/"

        // Create an item that would produce an empty last segment and is classified as a collection
        // using .article hint to force collection classification
        let resolved = ResolvedContent(
            items: [ImportItem(sourceURL: url, title: "Test", markdown: "m", rung: .readability, hint: .article)],
            homepage: nil, skippedURLs: [], problems: []
        )

        // Classify twice with the same fixed date and ensure identical slug
        let classified1 = ContentClassifier.classify(resolved, now: fixedDate)
        let classified2 = ContentClassifier.classify(resolved, now: fixedDate)

        // Both classifications should produce identical output
        guard case .collection(let name1, let slug1) = classified1.first?.destination else {
            Issue.record("Expected collection destination for article hint")
            return
        }

        guard case .collection(let name2, let slug2) = classified2.first?.destination else {
            Issue.record("Expected collection destination for article hint on second call")
            return
        }

        #expect(name1 == name2)
        #expect(slug1 == slug2)

        // Verify the slug matches the expected deterministic value
        let expectedSlug = ContentScaffold.slugFromURL(url, now: fixedDate)
        #expect(slug1 == expectedSlug)
    }
}
