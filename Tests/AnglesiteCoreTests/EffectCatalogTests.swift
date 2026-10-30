// Tests/AnglesiteCoreTests/EffectCatalogTests.swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite struct EffectCatalogTests {
    @Test func loadsRealTemplateCatalog() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        #expect(!catalog.entries.isEmpty)
        for entry in catalog.entries {
            let demo = EffectCatalog.demoURL(templateDirectory: try templateRoot(), component: entry.component)
            #expect(FileManager.default.fileExists(atPath: demo.path), "\(entry.component)")
        }
    }

    @Test func groupsByCategory() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        let grouped = EffectCategory.allCases.flatMap { catalog.entries(in: $0) }
        #expect(grouped.count == catalog.entries.count)
    }

    @Test func onlyNewCategoriesArePlaceable() throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        let legacy: Set<EffectCategory> = [.text, .cards, .buttons, .backgrounds, .navigation]
        for entry in catalog.entries {
            if legacy.contains(entry.category) {
                #expect(entry.placement == nil, "\(entry.component) is a legacy micro-animation, should not be placeable")
            } else {
                #expect(entry.placement != nil, "\(entry.component) is a new effect, must declare placement")
            }
        }
    }

    @Test func decodesFromFixtureJSON() throws {
        let json = """
        {"version":2,"components":[
          {"component":"FadeInText","title":"Fade-in text","ownerDescription":"d","category":"text","keyProps":{},"snippet":"s"},
          {"component":"ParticleField","title":"Particle Field","ownerDescription":"d","category":"canvasBackground","keyProps":{},"snippet":"s","placement":{"kind":"background","allowedParents":null}}
        ]}
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("integrations"), withIntermediateDirectories: true)
        try json.write(to: tmp.appendingPathComponent("integrations/effects.json"), atomically: true, encoding: .utf8)
        let catalog = try EffectCatalog.load(templateDirectory: tmp)
        #expect(catalog.entries.count == 2)
        #expect(catalog.entries[0].placement == nil)
        #expect(catalog.entries[1].placement?.kind == .background)
    }

    // MARK: - Aliases + search (#2180)

    private func entry(_ component: String, title: String, description: String = "d", aliases: [String] = []) -> EffectCatalogEntry {
        EffectCatalogEntry(component: component, title: title, ownerDescription: description, category: .text, keyProps: [:], snippet: "s", aliases: aliases)
    }

    @Test func missingAliasesKeyDecodesToEmpty() throws {
        let json = #"{"component":"A","title":"t","ownerDescription":"d","category":"text","keyProps":{},"snippet":"s"}"#
        let decoded = try JSONDecoder().decode(EffectCatalogEntry.self, from: Data(json.utf8))
        #expect(decoded.aliases == [])
    }

    @Test func aliasesRoundTrip() throws {
        let original = entry("A", title: "t", aliases: ["text fades in", "soft entrance"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EffectCatalogEntry.self, from: data)
        #expect(decoded.aliases == ["text fades in", "soft entrance"])
        #expect(decoded == original)
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let catalog = EffectCatalog(entries: [
            entry("A", title: "Alpha", aliases: ["background slowly shimmers"]),
            entry("B", title: "Beta"),
        ])
        #expect(catalog.search("Shimmér").map(\.component) == ["A"])
    }

    @Test func searchStemsSuffixes() {
        let catalog = EffectCatalog(entries: [
            entry("A", title: "Alpha", aliases: ["letter bounces in"]),
            entry("B", title: "Beta", aliases: ["heading drifts in"]),
        ])
        #expect(catalog.search("bouncing").map(\.component) == ["A"])
        #expect(catalog.search("bounced").map(\.component) == ["A"])
        #expect(catalog.search("drift").map(\.component) == ["B"])
    }

    @Test func aliasOrTitleHitOutranksDescriptionOnlyHit() {
        let catalog = EffectCatalog(entries: [
            entry("A", title: "Alpha", description: "A glowing shimmer"),
            entry("B", title: "Beta", aliases: ["shimmer"]),
            entry("C", title: "Shimmer"),
        ])
        #expect(catalog.search("shimmer").map(\.component) == ["B", "C", "A"])
    }

    @Test func prefixMatchScoresHalfWeight() {
        let catalog = EffectCatalog(entries: [
            entry("A", title: "Alpha", aliases: ["shimmering glow"]),
            entry("B", title: "Beta", aliases: ["shimmer"]),
        ])
        // "shimmer" exact (3) beats prefix of "shimmering" (stem "shimmer" == exact after stemming),
        // so use a true prefix: "shim".
        #expect(catalog.search("shim").map(\.component) == ["A", "B"])
        let weighted = EffectCatalog(entries: [
            entry("A", title: "Alpha", description: "shimmer here"),
            entry("B", title: "Beta", aliases: ["shimmery"]),
        ])
        #expect(weighted.search("shim").map(\.component) == ["B", "A"])
    }

    @Test func tiesKeepManifestOrder() {
        let catalog = EffectCatalog(entries: [
            entry("Z", title: "Zed", aliases: ["glow"]),
            entry("A", title: "Aye", aliases: ["glow"]),
            entry("M", title: "Em", aliases: ["glow"]),
        ])
        #expect(catalog.search("glow").map(\.component) == ["Z", "A", "M"])
    }

    @Test func emptyOrStopWordQueryReturnsAllInOrder() {
        let catalog = EffectCatalog(entries: [entry("Z", title: "Zed"), entry("A", title: "Aye")])
        #expect(catalog.search("").map(\.component) == ["Z", "A"])
        #expect(catalog.search("   ").map(\.component) == ["Z", "A"])
        #expect(catalog.search("the of a").map(\.component) == ["Z", "A"])
    }

    @Test func nonsenseQueryReturnsNothing() {
        let catalog = EffectCatalog(entries: [entry("A", title: "Alpha", aliases: ["glow"])])
        #expect(catalog.search("xqzvw").isEmpty)
    }

    @Test(arguments: [
        ("letters bounce in one at a time", "TypewriterText"),
        ("background slowly shimmers", "AuroraGradient"),
        ("heading drifts in", "FadeInText"),
    ])
    func realCatalogAnswersOwnerPhrases(phrase: String, expected: String) throws {
        let catalog = try EffectCatalog.load(templateDirectory: try templateRoot())
        let results = catalog.search(phrase)
        #expect(!results.isEmpty, "\(phrase)")
        #expect(results.first?.component == expected, "\(phrase) → \(results.first?.component ?? "none")")
    }
}
