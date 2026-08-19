// Tests/AnglesiteCoreTests/PlacementMatcherTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct PlacementMatcherTests {
    /// `<body id="body"><header></header><section class="hero">target</section><footer></footer></body>`
    /// as a two-level PageModel tree: fragment(n0) -> body(n1) -> [header(n2), section.hero(n3), footer(n4)]
    static func fixtureModel() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let body = node("n1", kind: .element, tag: "BODY", attrs: [.init(name: "id", value: "body")], children: [
            node("n2", kind: .element, tag: "HEADER"),
            node("n3", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "hero")]),
            node("n4", kind: .element, tag: "FOOTER"),
        ])
        let root = node("n0", kind: .fragment, tag: nil, children: [body])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    static func elementInfo(tag: String, classes: [String] = [], nthChild: Int, ancestorTags: [(String, String?)]) -> ElementInfo {
        ElementInfo(
            tag: tag, id: nil, classes: classes, nthChild: nthChild,
            ancestors: ancestorTags.map { AncestorInfo(tag: $0.0, id: $0.1, classes: [], nthChild: nil, role: nil, ariaLabel: nil) },
            dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil)
    }

    @Test func inlinePlacementInsertsAfterMatchedNode() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 2) // after n3 (index 1 among [n2,n3,n4]) -> insert at 2
    }

    @Test func backgroundPlacementInsertsAsFirstChildOfParent() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .background, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 0)
    }

    @Test func noMatchWhenTagAndAncestryDontLineUp() {
        let element = Self.elementInfo(tag: "ARTICLE", nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        #expect(result == .failure(.noMatch))
    }

    @Test func allowedParentsRestrictsMatch() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: ["MAIN"])
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement)
        #expect(result == .failure(.noMatch)) // parent is BODY, not MAIN
    }

    /// Fixture with mixed element and non-element siblings to test full-array-index tracking.
    /// `<body>{expr0} <header></header> <section class="hero"></section> <footer></footer></body>`
    /// Full children: [expr0(.expression), header, section.hero, footer] at indices [0,1,2,3]
    /// Element-only: [header, section.hero, footer] at element-indices [0,1,2]
    /// section.hero has nthChild=2 (position 2 among elements, after header at position 1).
    /// Must use full-array index 2 for insertion, not element-only index 1.
    static func fixtureModelWithMixedSiblings() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let body = node("n1", kind: .element, tag: "BODY", attrs: [.init(name: "id", value: "body")], children: [
            node("expr0", kind: .expression, tag: nil),  // full index 0, not counted in nthChild
            node("n2", kind: .element, tag: "HEADER"),   // full index 1, nthChild position 1
            node("n3", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "hero")]), // full index 2, nthChild position 2
            node("n4", kind: .element, tag: "FOOTER"),   // full index 3, nthChild position 3
        ])
        let root = node("n0", kind: .fragment, tag: nil, children: [body])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    @Test func inlinePlacementWithMixedSiblingsUsesFullArrayIndex() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModelWithMixedSiblings(), placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        // section.hero is at full-array index 2, so insertion index = 2 + 1 = 3 (not 1 + 1 = 2)
        #expect(insertion.index == 3)
    }

    /// Fixture with two SECTION elements at nthChild position 1 in different parents,
    /// ensuring the same (tag, nthChild) pair can appear at multiple tree locations.
    /// Both section.a nodes match; result should be .ambiguous.
    static func fixtureModelAmbiguous() -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let section1 = node("s1", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "a")])
        let section2 = node("s2", kind: .element, tag: "SECTION", attrs: [.init(name: "class", value: "a")])
        let parent1 = node("p1", kind: .element, tag: "DIV", children: [section1])
        let parent2 = node("p2", kind: .element, tag: "DIV", children: [section2])
        let root = node("n0", kind: .fragment, tag: nil, children: [parent1, parent2])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    @Test func ambiguousWhenMultipleNodesMatch() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["a"], nthChild: 1, ancestorTags: [("DIV", nil)])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(element: element, in: Self.fixtureModelAmbiguous(), placement: placement)
        #expect(result == .failure(.ambiguous))
    }

    // MARK: - Before/after toggle (#768 final review, Finding 6)

    @Test func inlinePlacementCanInsertBeforeTheMatchedNode() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)
        let result = PlacementMatcher.resolve(
            element: element, in: Self.fixtureModel(), placement: placement, inlinePosition: .before)
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 1) // at n3's own slot, pushing it down — i.e. before it
    }

    @Test func inlinePositionIsIgnoredByBackgroundPlacements() {
        let element = Self.elementInfo(tag: "SECTION", classes: ["hero"], nthChild: 2, ancestorTags: [("BODY", "body")])
        let placement = EffectCatalogEntry.Placement(kind: .background, allowedParents: nil)
        let before = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement, inlinePosition: .before)
        let after = PlacementMatcher.resolve(element: element, in: Self.fixtureModel(), placement: placement, inlinePosition: .after)
        #expect(before == after)
    }

    // MARK: - Identity-attribute priority (#768 final review, Finding 5)

    /// `<body><div><span id="pick" data-testid="t" data-anglesite-id="a"/></div><div><span/></div></body>`
    /// — the identity attributes sit on a node the positional matcher would call `.ambiguous`
    /// (two SPANs, both first-in-parent, both under a DIV).
    static func fixtureModelWithIdentityAttributes(
        onTarget attrs: [PageModel.Attr]
    ) -> PageModel {
        func node(_ id: String, kind: PageModel.Node.Kind, tag: String?, attrs: [PageModel.Attr] = [], children: [PageModel.Node] = []) -> PageModel.Node {
            PageModel.Node(id: id, kind: kind, tag: tag, attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: children, block: nil)
        }
        let target = node("target", kind: .element, tag: "SPAN", attrs: attrs)
        let decoy = node("decoy", kind: .element, tag: "SPAN")
        let root = node("n0", kind: .fragment, tag: nil, children: [
            node("d1", kind: .element, tag: "DIV", children: [target]),
            node("d2", kind: .element, tag: "DIV", children: [decoy]),
        ])
        return PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
    }

    static func elementInfoWithIdentity(id: String? = nil, dataTestId: String? = nil, dataAnglesiteId: String? = nil) -> ElementInfo {
        ElementInfo(
            tag: "SPAN", id: id, classes: [], nthChild: 1, ancestors: [],
            dataAnglesiteId: dataAnglesiteId, dataTestId: dataTestId, role: nil, ariaLabel: nil, textContent: nil)
    }

    @Test func dataAnglesiteIdResolvesAnOtherwiseAmbiguousClick() {
        let model = Self.fixtureModelWithIdentityAttributes(onTarget: [.init(name: "data-anglesite-id", value: "a1")])
        let placement = EffectCatalogEntry.Placement(kind: .inline, allowedParents: nil)

        // Without the identity signal this exact click is ambiguous…
        #expect(PlacementMatcher.resolve(element: Self.elementInfoWithIdentity(), in: model, placement: placement) == .failure(.ambiguous))

        // …and with it, it resolves to the one node carrying the attribute.
        let result = PlacementMatcher.resolve(
            element: Self.elementInfoWithIdentity(dataAnglesiteId: "a1"), in: model, placement: placement)
        guard case .success(let insertion) = result else {
            Issue.record("expected the data-anglesite-id match")
            return
        }
        #expect(insertion.parentId == "d1")
        #expect(insertion.index == 1)
    }

    @Test func dataTestIdResolvesAnOtherwiseAmbiguousClick() {
        let model = Self.fixtureModelWithIdentityAttributes(onTarget: [.init(name: "data-testid", value: "t1")])
        let result = PlacementMatcher.resolve(
            element: Self.elementInfoWithIdentity(dataTestId: "t1"), in: model,
            placement: .init(kind: .inline, allowedParents: nil))
        guard case .success(let insertion) = result else {
            Issue.record("expected the data-testid match")
            return
        }
        #expect(insertion.parentId == "d1")
    }

    @Test func idResolvesAnOtherwiseAmbiguousClick() {
        let model = Self.fixtureModelWithIdentityAttributes(onTarget: [.init(name: "id", value: "pick")])
        let result = PlacementMatcher.resolve(
            element: Self.elementInfoWithIdentity(id: "pick"), in: model,
            placement: .init(kind: .inline, allowedParents: nil))
        guard case .success(let insertion) = result else {
            Issue.record("expected the #id match")
            return
        }
        #expect(insertion.parentId == "d1")
    }

    @Test func dataAnglesiteIdWinsOverDataTestIdAndId() {
        func node(_ id: String, attrs: [PageModel.Attr]) -> PageModel.Node {
            PageModel.Node(id: id, kind: .element, tag: "SPAN", attrs: attrs, span: .init(start: nil, end: nil), loc: nil, text: nil, children: [], block: nil)
        }
        let root = PageModel.Node(
            id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil,
            children: [
                node("byAnglesiteId", attrs: [.init(name: "data-anglesite-id", value: "a1")]),
                node("byTestId", attrs: [.init(name: "data-testid", value: "t1")]),
                node("byId", attrs: [.init(name: "id", value: "pick")]),
            ], block: nil)
        let model = PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
        let element = ElementInfo(
            tag: "SPAN", id: "pick", classes: [], nthChild: 1, ancestors: [],
            dataAnglesiteId: "a1", dataTestId: "t1", role: nil, ariaLabel: nil, textContent: nil)

        let result = PlacementMatcher.resolve(element: element, in: model, placement: .init(kind: .inline, allowedParents: nil))
        guard case .success(let insertion) = result else {
            Issue.record("expected a match")
            return
        }
        #expect(insertion.parentId == "n0")
        #expect(insertion.index == 1) // after `byAnglesiteId` (index 0) — the highest-priority hit
    }

    @Test func anIdentityAttributeTheTreeDoesntCarryFallsBackToPositionalMatching() {
        // The overlay reports an id (e.g. one a client-side script added at runtime) that the
        // source tree has no trace of — the positional match must still get its turn.
        let element = ElementInfo(
            tag: "SECTION", id: "added-at-runtime", classes: ["hero"], nthChild: 2, ancestors: [],
            dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil)
        let result = PlacementMatcher.resolve(
            element: element, in: Self.fixtureModel(), placement: .init(kind: .inline, allowedParents: nil))
        guard case .success(let insertion) = result else {
            Issue.record("expected the positional fallback to match")
            return
        }
        #expect(insertion.parentId == "n1")
        #expect(insertion.index == 2)
    }

    @Test func duplicatedIdentityAttributesAreAmbiguousRatherThanAGuess() {
        func node(_ id: String) -> PageModel.Node {
            PageModel.Node(id: id, kind: .element, tag: "SPAN", attrs: [.init(name: "id", value: "dupe")], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [], block: nil)
        }
        let root = PageModel.Node(
            id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil,
            children: [node("a"), node("b")], block: nil)
        let model = PageModel(version: "v1", path: "src/pages/index.astro", tree: root)
        let result = PlacementMatcher.resolve(
            element: Self.elementInfoWithIdentity(id: "dupe"), in: model,
            placement: .init(kind: .inline, allowedParents: nil))
        #expect(result == .failure(.ambiguous))
    }
}
