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
}
