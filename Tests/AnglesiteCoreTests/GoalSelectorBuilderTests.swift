import Testing
@testable import AnglesiteCore

@Suite struct GoalSelectorBuilderTests {
    @Test func prefersDataAnglesiteId() {
        let info = ElementInfo(
            tag: "DIV", id: "reviews", classes: ["astro-abc123", "card"], nthChild: 2,
            ancestors: [], dataAnglesiteId: "reviews-section", dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "[data-anglesite-id=\"reviews-section\"]")
    }

    @Test func fallsBackToIdWhenNoDataAttributes() {
        let info = ElementInfo(
            tag: "SECTION", id: "pricing", classes: [], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "#pricing")
    }

    @Test func fallsBackToRoleAndAriaLabel() {
        let info = ElementInfo(
            tag: "NAV", id: nil, classes: [], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: "navigation", ariaLabel: "Primary", textContent: nil)
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "[role=\"navigation\"][aria-label=\"Primary\"]")
    }

    @Test func filtersAstroScopedHashClassesAndUsesStableClasses() {
        let info = ElementInfo(
            tag: "DIV", id: nil, classes: ["astro-xY9z1", "testimonial-card"], nthChild: 1,
            ancestors: [], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "div.testimonial-card")
    }

    @Test func fallsBackToTagAndNthChildWithAncestorChain() {
        let ancestor = AncestorInfo(tag: "SECTION", id: "testimonials", classes: [], nthChild: 3, role: nil, ariaLabel: nil)
        let info = ElementInfo(
            tag: "P", id: nil, classes: ["astro-only"], nthChild: 2,
            ancestors: [ancestor], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "#testimonials > p:nth-child(2)")
    }

    @Test func noStableIdentifierAnywhereInChainFails() {
        let ancestor = AncestorInfo(tag: "DIV", id: nil, classes: ["astro-x"], nthChild: 1, role: nil, ariaLabel: nil)
        let info = ElementInfo(
            tag: "SPAN", id: nil, classes: ["astro-y"], nthChild: 1,
            ancestors: [ancestor], dataAnglesiteId: nil, dataTestId: nil,
            role: nil, ariaLabel: nil, textContent: nil)
        // No ancestor to anchor on and the leaf has no stable identifier either: falls back to a
        // bare tag:nth-child chain rather than failing — still buildable, just less specific.
        #expect((try? GoalSelectorBuilder.build(for: info).get()) == "div:nth-child(1) > span:nth-child(1)")
    }
}
