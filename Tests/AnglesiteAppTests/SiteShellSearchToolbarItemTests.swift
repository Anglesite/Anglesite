import Testing
import AppKit
import AnglesiteTestSupport
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

    /// The "belt" half of `scopeMenuTemplate()`'s belt-and-suspenders fix: `selectScope(_:)` must
    /// update checked state itself, without relying on `menuNeedsUpdate(_:)` ever being called —
    /// per Apple's guidance, AppKit may only ever track a *copy* of `searchMenuTemplate`, never the
    /// template instance, in which case the delegate callback would never fire on it in real use.
    @Test("selecting a scope item updates checked state immediately, with no menuNeedsUpdate call")
    func selectingScopeUpdatesCheckedStateImmediately() {
        let model = makeModel()
        let item = SiteShellSearchToolbarItem(model: model, activate: { _ in })
        let menu = try! #require(item.searchField.searchMenuTemplate)
        let target = try! #require(
            menu.items.first { ($0.representedObject as? SiteSearchScope) == .posts })

        _ = target.target?.perform(target.action, with: target)

        for menuItem in menu.items {
            let scope = menuItem.representedObject as? SiteSearchScope
            #expect(menuItem.state == (scope == .posts ? .on : .off))
        }
    }

    /// Regression coverage for the observation-driven re-presentation path: `controlTextDidChange`
    /// alone shows whatever `model.hits` held from the *previous* query, since
    /// `SiteSearchModel.search(siteID:)` is async with a debounce and assigns `hits` later.
    /// `observeHits()` is what re-presents once the real results land — and must re-register after
    /// every fire, not just the first. Drives `model.hits` through the real
    /// `SiteSearchModel.search(siteID:)` path (its setter is `private(set)`, so nothing outside
    /// `SiteSearchModel` can assign it directly) against a real two-page fixture, one query per
    /// page so the two result sets are guaranteed to differ in content. Uses `presentationHandler`
    /// (a test seam) instead of the real `NSMenu.popUp` path: no test in this codebase exercises
    /// `.popUp(` directly, and its behavior with no window behind the view (as here, headless) is
    /// unspecified by Apple's docs, so routing around it is deliberate, not a shortcut.
    @Test("model.hits changes trigger presentSuggestions, and observation re-registers after firing")
    func hitsObservationFiresAndReRegisters() async throws {
        let root = try writeSiteTree(prefix: "shellsearchobs", [
            "src/pages/about.astro": "---\ntitle: About\n---\n# About\nAbout the studio.",
            "src/pages/contact.astro": "---\ntitle: Contact\n---\n# Contact\nGet in touch.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let model = SiteSearchModel(index: index)
        let item = SiteShellSearchToolbarItem(model: model, activate: { _ in })
        var presentationCount = 0
        item.presentationHandler = { presentationCount += 1 }

        model.query = "about"
        await model.search(siteID: "s")
        #expect(!model.hits.isEmpty, "fixture query must actually match, or this test proves nothing")
        try await waitUntil("first hits mutation to trigger a presentation") { presentationCount == 1 }

        // A second, differently-worded query only reaches the handler again if observeHits()
        // re-registered after the first fire — proving the tracking loop, not a one-shot callback.
        model.query = "contact"
        await model.search(siteID: "s")
        #expect(!model.hits.isEmpty, "fixture query must actually match, or this test proves nothing")
        try await waitUntil("second hits mutation to trigger another presentation (re-registration)") {
            presentationCount == 2
        }
    }
}
