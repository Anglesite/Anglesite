import AppKit
import Observation
import AnglesiteCore

/// The AppKit shell's owned search field (#1699 Stage 3 slice 2, design doc §"Toolbar (slice
/// 2)"): an `NSSearchToolbarItem` over the same `SiteSearchModel` the legacy `.searchable`
/// modifier drives, with a suggestions `NSMenu` standing in for `.searchSuggestions`'s popover
/// list. Scope switching (`SiteSearchScope`) is exposed via the search field's own
/// `searchMenuTemplate`, matching the platform convention for a scope-bar-less search field.
@MainActor
final class SiteShellSearchToolbarItem: NSSearchToolbarItem {
    static let identifier = NSToolbarItem.Identifier("site.shell.search")

    private let model: SiteSearchModel
    private let activate: (SiteSearchIndex.Hit) -> Void
    private var searchFieldDelegateBox: SearchFieldDelegateBox?

    init(model: SiteSearchModel, activate: @escaping (SiteSearchIndex.Hit) -> Void) {
        self.model = model
        self.activate = activate
        super.init(itemIdentifier: Self.identifier)
        toolTip = "Search Site"
        searchField.placeholderString = "Search Site"
        searchField.stringValue = model.query
        let scopeMenu = scopeMenuTemplate()
        scopeMenu.delegate = self
        searchField.searchMenuTemplate = scopeMenu
        let box = SearchFieldDelegateBox(owner: self)
        searchFieldDelegateBox = box
        searchField.delegate = box
        observeHits()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteShellSearchToolbarItem is code-constructed only")
    }

    /// Builds the menu items for a set of search hits — pure and testable without a window.
    /// Mirrors `SiteSearchSuggestionRow`'s title logic (`SiteSearchField.swift`): the front-matter
    /// title when there is one, else the filename.
    static func suggestionMenuItems(
        for hits: [SiteSearchIndex.Hit], onSelect: @escaping (SiteSearchIndex.Hit) -> Void
    ) -> [NSMenuItem] {
        hits.map { hit in
            let title = hit.title?.isEmpty == false ? hit.title! : (hit.path as NSString).lastPathComponent
            let item = SelectableMenuItem(title: title, hit: hit, onSelect: onSelect)
            item.target = item
            item.action = #selector(SelectableMenuItem.select)
            return item
        }
    }

    /// One `NSMenuItem` per `SiteSearchScope`, self-targeted so picking one updates `model.scope`
    /// (`NSMenuItem.target` is `weak`, so this doesn't retain-cycle). Built once at init — scope
    /// cases are static, unlike the suggestions menu — but checked state can't be set here: it's
    /// installed as `searchField.searchMenuTemplate`, which AppKit copies fresh every time it
    /// shows the menu rather than displaying this instance directly, so a `.state` set now would
    /// go stale the moment `model.scope` next changes. `menuNeedsUpdate(_:)` below (the
    /// `NSMenuDelegate` conformance, mirroring `SiteShellToolbarDelegate`'s Insert menu) refreshes
    /// it on the template right before AppKit copies it for display instead.
    private func scopeMenuTemplate() -> NSMenu {
        let menu = NSMenu()
        for scope in SiteSearchScope.allCases {
            let item = NSMenuItem(
                title: scope.menuItemTitle, action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scope
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let scope = sender.representedObject as? SiteSearchScope else { return }
        model.scope = scope
    }

    /// Registers (and, on every fire, re-registers) an `Observation` tracking closure over
    /// `model.hits`, so the suggestions menu updates once the debounced, async
    /// `SiteSearchModel.search(siteID:)` actually lands results. `controlTextDidChange` alone
    /// isn't enough: it calls `presentSuggestions()` synchronously right after writing
    /// `model.query`, but `search(siteID:)` is driven externally with a 150ms debounce and only
    /// assigns `hits` once that resolves — so without this, the menu would always show whatever
    /// `hits` held from the *previous* query and never refresh once the real results land.
    /// `withObservationTracking`'s `onChange` fires exactly once per registration, hence the
    /// recursive re-registration; `[weak self]` lets the chain stop cleanly once this item is
    /// deallocated instead of retaining it forever.
    private func observeHits() {
        withObservationTracking {
            _ = model.hits
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.presentSuggestions()
                self?.observeHits()
            }
        }
    }

    /// Shows the suggestions menu for the model's current `hits`, positioned under the search
    /// field — called both by the delegate box on every text change and by `observeHits()` once
    /// the debounced search actually lands new `hits`.
    fileprivate func presentSuggestions() {
        guard !model.hits.isEmpty else { return }
        let menu = NSMenu()
        menu.items = Self.suggestionMenuItems(for: model.hits, onSelect: activate)
        let origin = NSPoint(x: 0, y: searchField.bounds.minY)
        menu.popUp(positioning: nil, at: origin, in: searchField)
    }

    fileprivate func submit() {
        if let hit = model.submit() { activate(hit) }
    }

    /// One `NSMenuItem` subclass per hit rather than an associated-object lookup — keeps
    /// `onSelect` type-safe and avoids `objc_setAssociatedObject`.
    private final class SelectableMenuItem: NSMenuItem {
        let hit: SiteSearchIndex.Hit
        private let onSelect: (SiteSearchIndex.Hit) -> Void

        init(title: String, hit: SiteSearchIndex.Hit, onSelect: @escaping (SiteSearchIndex.Hit) -> Void) {
            self.hit = hit
            self.onSelect = onSelect
            super.init(title: title, action: nil, keyEquivalent: "")
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError() }

        @objc func select() { onSelect(hit) }
    }

    /// `NSSearchField`'s delegate must be an `NSObject`; this box exists only so
    /// `SiteShellSearchToolbarItem` itself (an `NSToolbarItem` subclass, not an `NSResponder`)
    /// doesn't have to conform directly.
    private final class SearchFieldDelegateBox: NSObject, NSSearchFieldDelegate {
        weak var owner: SiteShellSearchToolbarItem?
        init(owner: SiteShellSearchToolbarItem) { self.owner = owner }

        func controlTextDidChange(_ obligation: Notification) {
            guard let field = obligation.object as? NSSearchField else { return }
            owner?.model.query = field.stringValue
            owner?.presentSuggestions()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            owner?.submit()
            return true
        }
    }
}

extension SiteShellSearchToolbarItem: NSMenuDelegate {
    /// Keeps the scope menu's checked state in sync with `model.scope`. `menu` here is the
    /// *template* (`searchField.searchMenuTemplate`), not the transient copy AppKit actually
    /// displays — mirrors `SiteShellToolbarDelegate.menuNeedsUpdate(_:)`, the only other place in
    /// the shell that has to refresh a template menu's contents right before it's shown rather
    /// than keep them live-bound.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let scope = item.representedObject as? SiteSearchScope else { continue }
            item.state = scope == model.scope ? .on : .off
        }
    }
}
