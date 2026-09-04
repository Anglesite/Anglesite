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

    private func makeModel() -> SiteSearchModel {
        SiteSearchModel(index: SiteKnowledgeIndex())
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

    /// Regression coverage for the scope menu previously being decorative (no target/action, no
    /// checked state) despite the class's own doc comment claiming scope switching worked through
    /// `searchMenuTemplate`. Exercises `selectScope(_:)` directly through the menu item's
    /// target/action, the same path a real click drives — no window needed since nothing here
    /// calls `NSMenu.popUp`.
    @Test("selecting a scope menu item updates model.scope")
    func selectingScopeUpdatesModel() {
        let model = makeModel()
        let item = SiteShellSearchToolbarItem(model: model, activate: { _ in })
        let menu = try! #require(item.searchField.searchMenuTemplate)
        let target = try! #require(
            menu.items.first { ($0.representedObject as? SiteSearchScope) == .posts })
        #expect(target.action != nil, "scope item needs a real action, not the decorative nil the brief shipped")
        _ = target.target?.perform(target.action, with: target)
        #expect(model.scope == .posts)
    }

    /// `menuNeedsUpdate(_:)` is what keeps the scope menu's checkmark honest — the template
    /// AppKit copies for display isn't live-bound to `model.scope`, so nothing else refreshes it.
    @Test("menuNeedsUpdate checks the item matching model.scope, unchecks the rest")
    func menuNeedsUpdateChecksCurrentScope() {
        let model = makeModel()
        model.scope = .components
        let item = SiteShellSearchToolbarItem(model: model, activate: { _ in })
        let menu = try! #require(item.searchField.searchMenuTemplate)

        item.menuNeedsUpdate(menu)

        for menuItem in menu.items {
            let scope = menuItem.representedObject as? SiteSearchScope
            #expect(menuItem.state == (scope == .components ? .on : .off))
        }
    }
}
