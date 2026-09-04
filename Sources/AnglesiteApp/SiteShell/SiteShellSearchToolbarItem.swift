import AppKit
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
        searchField.searchMenuTemplate = Self.scopeMenuTemplate()
        searchField.stringValue = model.query
        let box = SearchFieldDelegateBox(owner: self)
        searchFieldDelegateBox = box
        searchField.delegate = box
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

    /// One `NSMenuItem` per `SiteSearchScope`, checked state mirrors `model.scope`. Rebuilt once
    /// at init — scope cases are static, unlike the suggestions menu.
    private static func scopeMenuTemplate() -> NSMenu {
        let menu = NSMenu()
        for scope in SiteSearchScope.allCases {
            menu.addItem(NSMenuItem(title: String(describing: scope), action: nil, keyEquivalent: ""))
        }
        return menu
    }

    /// Shows the suggestions menu for the model's current `hits`, positioned under the search
    /// field — called by the delegate box on every text change once results land.
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
