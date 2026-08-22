import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportRedirectsTests {
    private func item(sourceURL: String) -> ImportItem {
        ImportItem(sourceURL: sourceURL, title: "T", markdown: "m", rung: .readability, hint: .none)
    }

    @Test("dated WP permalink redirects to its new blog route")
    func datedPermalinkRedirectsToBlogRoute() {
        let classified = ClassifiedItem(
            item: item(sourceURL: "https://example.com/2024/05/01/hello/"),
            destination: .collection(name: "blog", slug: "hello")
        )

        let entries = RedirectsEmitter.entries(for: [classified])

        #expect(entries == [
            RedirectEntry(source: "/2024/05/01/hello/", destination: "/blog/hello/", code: 301),
        ])
    }

    @Test("a page already served at its classified route produces no redirect")
    func unchangedPageRouteProducesNoRedirect() {
        let classified = ClassifiedItem(
            item: item(sourceURL: "https://example.com/about"),
            destination: .page(route: "/about")
        )

        let entries = RedirectsEmitter.entries(for: [classified])

        #expect(entries.isEmpty)
    }

    @Test("merging the same entries twice does not duplicate")
    func mergingTwiceDoesNotDuplicate() throws {
        let entry = RedirectEntry(source: "/2024/05/01/hello/", destination: "/blog/hello/", code: 301)

        let firstMerge = try RedirectsEmitter.merge(existingJSON: "[]", adding: [entry])
        let secondMerge = try RedirectsEmitter.merge(existingJSON: firstMerge, adding: [entry])

        #expect(secondMerge == firstMerge)

        let decoded = try JSONDecoder().decode([RedirectEntry].self, from: Data(secondMerge.utf8))
        #expect(decoded == [entry])
    }

    @Test("servedPath for a collection uses /<name>/<slug>/")
    func servedPathForCollection() {
        #expect(RedirectsEmitter.servedPath(for: .collection(name: "notes", slug: "n-1")) == "/notes/n-1/")
    }

    @Test("servedPath for a page uses the trailing-slash-normalized route")
    func servedPathForPage() {
        #expect(RedirectsEmitter.servedPath(for: .page(route: "/about")) == "/about/")
    }

    @Test("entries dedupes by source")
    func entriesDedupesBySource() {
        let classifiedA = ClassifiedItem(
            item: item(sourceURL: "https://example.com/2024/05/01/hello/"),
            destination: .collection(name: "blog", slug: "hello")
        )
        let classifiedB = ClassifiedItem(
            item: item(sourceURL: "https://example.com/2024/05/01/hello"),
            destination: .collection(name: "blog", slug: "hello-again")
        )

        let entries = RedirectsEmitter.entries(for: [classifiedA, classifiedB])

        #expect(entries.count == 1)
        #expect(entries.first?.source == "/2024/05/01/hello/")
    }

    @Test("merge appends new entries alongside existing ones")
    func mergeAppendsNewEntries() throws {
        let existing = RedirectEntry(source: "/old-1/", destination: "/blog/one/", code: 301)
        let existingJSON = try RedirectsEmitter.merge(existingJSON: "[]", adding: [existing])

        let added = RedirectEntry(source: "/old-2/", destination: "/blog/two/", code: 301)
        let merged = try RedirectsEmitter.merge(existingJSON: existingJSON, adding: [added])

        let decoded = try JSONDecoder().decode([RedirectEntry].self, from: Data(merged.utf8))
        #expect(decoded.count == 2)
        #expect(decoded.contains(existing))
        #expect(decoded.contains(added))
    }

    @Test("merge output is pretty-printed with sorted keys and a trailing newline")
    func mergeOutputFormat() throws {
        let entry = RedirectEntry(source: "/old/", destination: "/new/", code: 301)
        let merged = try RedirectsEmitter.merge(existingJSON: "[]", adding: [entry])

        #expect(merged.hasSuffix("\n"))
        #expect(merged.contains("\"code\""))
        // sortedKeys places "code" before "destination" before "source"
        let codeIndex = merged.range(of: "\"code\"")?.lowerBound
        let destinationIndex = merged.range(of: "\"destination\"")?.lowerBound
        let sourceIndex = merged.range(of: "\"source\"")?.lowerBound
        #expect(codeIndex != nil && destinationIndex != nil && sourceIndex != nil)
        if let c = codeIndex, let d = destinationIndex, let s = sourceIndex {
            #expect(c < d)
            #expect(d < s)
        }
    }

    @Test("merge throws on malformed existing JSON")
    func mergeThrowsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try RedirectsEmitter.merge(existingJSON: "not json", adding: [])
        }
    }
}
