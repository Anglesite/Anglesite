import Testing
import AppKit
@testable import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("SiteShellSearchToolbarItem")
@MainActor
struct SiteShellSearchToolbarItemTests {
    /// `SiteSearchIndex.Hit` has no public initializer (it's built only by
    /// `SiteSearchIndex.search`), so this test file needs `@testable import AnglesiteCore` too —
    /// not just `AnglesiteAppCore` — to reach its internal memberwise init. Field order matches
    /// the real declaration (`id`, `kind`, `title`, `route`, `path`, `matchContext`, `score`),
    /// not the brief's guess.
    private func hit(path: String, title: String?) -> SiteSearchIndex.Hit {
        SiteSearchIndex.Hit(
            id: path, kind: .page, title: title, route: nil, path: path, matchContext: "",
            score: 0)
    }

    @Test("empty hits produce no menu items")
    func emptyHitsProduceNoItems() {
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(for: [], onSelect: { _ in })
        #expect(items.isEmpty)
    }

    @Test("each hit becomes one menu item titled by its display title")
    func hitsBecomeTitledMenuItems() {
        let hits = [
            hit(path: "src/pages/about.astro", title: "About"),
            hit(path: "src/pages/contact.astro", title: nil),
        ]
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(for: hits, onSelect: { _ in })
        #expect(items.map(\.title) == ["About", "contact.astro"])
    }

    @Test("selecting a menu item invokes onSelect with its hit")
    func selectingItemInvokesOnSelect() {
        let target = hit(path: "src/pages/about.astro", title: "About")
        var selected: SiteSearchIndex.Hit?
        let items = SiteShellSearchToolbarItem.suggestionMenuItems(
            for: [target], onSelect: { selected = $0 })
        let item = try! #require(items.first)
        _ = item.target?.perform(item.action, with: item)
        #expect(selected?.path == target.path)
    }
}
