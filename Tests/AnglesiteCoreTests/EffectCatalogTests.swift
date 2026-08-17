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
}
