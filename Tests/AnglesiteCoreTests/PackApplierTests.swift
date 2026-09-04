import Testing
import Foundation
@testable import AnglesiteCore

struct PackApplierTests {
    private let template: URL
    private let site: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        template = base.appendingPathComponent("template")
        site = base.appendingPathComponent("site")
        // Minimal scaffolded site: base global.css + a page the pack does NOT override.
        try Self.write("::root base", to: site.appendingPathComponent("src/styles/global.css"))
        try Self.write("<h1>About</h1>", to: site.appendingPathComponent("src/pages/about.astro"))
        // Pack overlay: replaces global.css, adds a component in a nested dir, ships a LICENSE.
        let pack = template.appendingPathComponent("packs/paper")
        try Self.write(":root { --pack: 1 }", to: pack.appendingPathComponent("src/styles/global.css"))
        try Self.write("<nav/>", to: pack.appendingPathComponent("src/components/PaperNav.astro"))
        try Self.write("MIT License — upstream", to: pack.appendingPathComponent("LICENSE"))
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test("apply overlays replaces and adds files")
    func applyOverlaysReplacesAndAddsFiles() throws {
        try PackApplier.apply(packNamed: "paper", templateURL: template, siteDirectory: site)
        #expect(try read(site.appendingPathComponent("src/styles/global.css")) == ":root { --pack: 1 }")
        #expect(try read(site.appendingPathComponent("src/components/PaperNav.astro")) == "<nav/>")
        // Files the pack doesn't override survive.
        #expect(try read(site.appendingPathComponent("src/pages/about.astro")) == "<h1>About</h1>")
    }

    @Test("apply copies the LICENSE to the site root")
    func applyCopiesLicenseToSiteRoot() throws {
        try PackApplier.apply(packNamed: "paper", templateURL: template, siteDirectory: site)
        #expect(try read(site.appendingPathComponent(PackApplier.licenseFileName)) ==
                       "MIT License — upstream")
    }

    @Test("apply throws when the pack is missing")
    func applyThrowsWhenPackMissing() {
        #expect {
            try PackApplier.apply(packNamed: "nope", templateURL: template, siteDirectory: site)
        } throws: { error in
            guard case PackApplier.PackError.packNotFound = error else { return false }
            return true
        }
    }
}
