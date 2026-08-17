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
}
