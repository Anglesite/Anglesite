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
}
