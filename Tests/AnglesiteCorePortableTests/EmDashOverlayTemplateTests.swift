// Holds the template's EmDash overlay (Resources/Template/emdash/, #2050) to the template it
// sits on. The overlay carries a whole package.json and lockfile of its own, so a template
// dependency bump that isn't made in the overlay too would leave every new EmDash site behind.
// Portable target: pure Foundation over committed files, run by the Linux CI leg.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("EmDash template overlay (#2050)")
struct EmDashOverlayTemplateTests {
    private static let template = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Template", isDirectory: true)
    private static let overlay = EmDashScaffold.overlayURL(templateURL: template)

    /// The packages the owner approved for EmDash sites only (2026-09-29), exact-pinned.
    private static let emdashOnlyDependencies: Set<String> = ["@astrojs/cloudflare", "@emdash-cms/cloudflare", "emdash", "kysely"]
    /// Template dev dependencies an EmDash site needs at runtime, moved to `dependencies`.
    private static let movedToRuntime: Set<String> = ["react", "react-dom", "@astrojs/react"]
    /// Scripts the overlay changes: server output puts pages in `dist/client/`, and the overlay's
    /// own tests are part of the template's `npm test`, not the site's.
    private static let overlayScripts: Set<String> = ["build", "postbuild", "test"]

    private static func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func section(_ object: [String: Any], _ key: String) -> [String: String] {
        object[key] as? [String: String] ?? [:]
    }

    @Test("the overlay keeps every template dependency at the template's version")
    func dependenciesTrackTemplate() throws {
        let t = try Self.json(Self.template.appendingPathComponent("package.json"))
        let o = try Self.json(Self.overlay.appendingPathComponent("package.json"))
        let (tDeps, tDev) = (Self.section(t, "dependencies"), Self.section(t, "devDependencies"))
        let (oDeps, oDev) = (Self.section(o, "dependencies"), Self.section(o, "devDependencies"))
        for (name, version) in tDeps {
            #expect(oDeps[name] == version, "dependency \(name)")
        }
        for (name, version) in tDev {
            if Self.movedToRuntime.contains(name) {
                #expect(oDev[name] == nil, "\(name) moves to dependencies")
                #expect(oDeps[name] == version.trimmingCharacters(in: CharacterSet(charactersIn: "^~")), "\(name) is pinned")
            } else {
                #expect(oDev[name] == version, "devDependency \(name)")
            }
        }
        let extras = Set(oDeps.keys).subtracting(tDeps.keys).subtracting(Self.movedToRuntime)
            .union(Set(oDev.keys).subtracting(tDev.keys))
        #expect(extras == Self.emdashOnlyDependencies, "new packages need the owner's approval (CONTRIBUTING)")
        for name in Self.emdashOnlyDependencies {
            let version = try #require(oDeps[name], "\(name) is a runtime dependency")
            #expect(version.first?.isNumber == true, "\(name) is exact-pinned: \(version)")
        }
        #expect(o["overrides"] as? NSDictionary == t["overrides"] as? NSDictionary)
    }

    @Test("the overlay's scripts are the template's, apart from build output and tests")
    func scriptsTrackTemplate() throws {
        let t = Self.section(try Self.json(Self.template.appendingPathComponent("package.json")), "scripts")
        let o = Self.section(try Self.json(Self.overlay.appendingPathComponent("package.json")), "scripts")
        #expect(Set(o.keys) == Set(t.keys))
        for (name, script) in t where !Self.overlayScripts.contains(name) {
            #expect(o[name] == script, "script \(name)")
        }
        #expect(o["test"] == t["test"]?.replacingOccurrences(of: #" "emdash/src/**/*.test.ts""#, with: ""))
        #expect(o["build"]?.contains("dist/client") == true)
    }

    @Test("the overlay's lockfile matches its package.json")
    func lockfileInSync() throws {
        let manifest = try Self.json(Self.overlay.appendingPathComponent("package.json"))
        let lock = try Self.json(Self.overlay.appendingPathComponent("package-lock.json"))
        let root = try #require((lock["packages"] as? [String: Any])?[""] as? [String: Any])
        #expect(lock["name"] as? String == manifest["name"] as? String)
        #expect(Self.section(root, "dependencies") == Self.section(manifest, "dependencies"))
        #expect(Self.section(root, "devDependencies") == Self.section(manifest, "devDependencies"))
    }

    /// #2088: an EmDash site's `THIRD-PARTY-NOTICES.md` is written from the overlay's own
    /// attribution set, so that set must exist, decode, and disclose the EmDash-only packages at
    /// the versions the overlay pins. (AttributionCatalogTests covers decoding of every committed
    /// manifest on macOS; this is the one that runs on the Linux leg.)
    @Test("the overlay's packages are attributed in the committed emdash-site manifest")
    func overlayPackagesAreAttributed() throws {
        let attributions = Self.template.deletingLastPathComponent().appendingPathComponent("Attributions", isDirectory: true)
        for source in AttributionSource.allCases {
            let url = attributions.appendingPathComponent("\(source.rawValue).json")
            let entries = try AttributionCatalog.decode(Data(contentsOf: url), source: source)
            #expect(!entries.isEmpty, "\(source.rawValue).json")
        }
        let manifest = try Self.json(Self.overlay.appendingPathComponent("package.json"))
        let pinned = Self.section(manifest, "dependencies")
        let emdashSite = try AttributionCatalog.decode(
            Data(contentsOf: attributions.appendingPathComponent("emdash-site.json")), source: .emdashSite)
        for name in Self.emdashOnlyDependencies {
            let version = try #require(pinned[name])
            #expect(emdashSite.contains { $0.name == name && $0.version == version }, "\(name)@\(version)")
            #expect(emdashSite.contains { $0.name == name && !$0.licenseText.isEmpty }, "\(name) license text")
        }
        #expect(AttributionSource.siteTemplate(for: .emdash) == .emdashSite)
        #expect(AttributionSource.siteTemplate(for: .anglesite) == .websiteTemplate)
    }

    @Test("an Anglesite site never gets the overlay, and the template's checks skip it")
    func overlayStaysOutOfAnglesiteSites() throws {
        let scaffold = try String(contentsOf: Self.template.appendingPathComponent("scripts/scaffold.sh"), encoding: .utf8)
        #expect(scaffold.contains("--exclude='emdash/'"))
        let tsconfig = try Self.json(Self.template.appendingPathComponent("tsconfig.json"))
        #expect((tsconfig["exclude"] as? [String])?.contains(EmDashScaffold.overlayDirectoryName) == true)
    }

    @Test("CI's overlay build skips exactly what the app's scaffold skips")
    func checkScriptMatchesScaffold() throws {
        let script = try String(contentsOf: Self.template.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/check-emdash-overlay.sh"), encoding: .utf8)
        let overlayCopy = try #require(script.components(separatedBy: #"mv "$SITE/astro.config.ts""#).last)
        let excludes = overlayCopy.components(separatedBy: "\n")
            .compactMap { line -> String? in
                guard let start = line.range(of: "--exclude='"), let end = line[start.upperBound...].firstIndex(of: "'")
                else { return nil }
                return String(line[start.upperBound..<end])
            }
        #expect(excludes.allSatisfy { $0.hasPrefix("/") }, "top-level only, like the app: \(excludes)")
        #expect(Set(excludes.map { String($0.dropFirst()) }) == EmDashScaffold.overlaySkippedNames)
    }

    @Test("the overlay wires the pinned render backstop into every server-rendered page")
    func middlewareWiresRenderBackstop() throws {
        let middleware = try String(contentsOf: Self.overlay.appendingPathComponent("src/middleware.ts"), encoding: .utf8)
        #expect(middleware.contains(#"from "../scripts/emdash-gate/render-backstop.ts""#))
        #expect(middleware.contains("d1WithheldReporter(db),"))
        #expect(middleware.contains("cfContext.waitUntil(promise)"))
        #expect(FileManager.default.fileExists(
            atPath: Self.template.appendingPathComponent("scripts/emdash-gate/render-backstop.ts").path))
    }

    @Test("the overlay's config builds on the renamed template config and registers the gate")
    func configRegistersGate() throws {
        let config = try String(contentsOf: Self.overlay.appendingPathComponent("astro.config.ts"), encoding: .utf8)
        #expect(config.contains(#"from "./\#(EmDashScaffold.templateConfigFileName)""#))
        #expect(config.contains(#"id: "anglesite-gate""#))
        #expect(config.contains("./scripts/emdash-gate/plugin.ts"))
        #expect(config.contains("plugins: [anglesiteGate]"))
        // The deploy layer (#2055 slice 2) refuses a server build without the pinned manifest.
        #expect(config.contains(#"from "./scripts/anglesite-build-manifest.ts""#))
        #expect(config.contains("anglesiteBuildManifest()"))
        // The gate's manifest and the in-code descriptor grant the same, single capability.
        let manifest = try String(contentsOf: Self.template.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JS/anglesite-gate/emdash-plugin.jsonc"), encoding: .utf8)
        #expect(manifest.contains(#""capabilities": ["hooks.content-policy:register"]"#))
        #expect(config.contains(#"capabilities: ["hooks.content-policy:register"]"#))
    }

    /// Template routes that list articles, which an EmDash site keeps in EmDash rather than in git
    /// collections (#2133). Each needs an overlay route that renders on request from EmDash, or it
    /// would ship empty.
    private static let articleListingRoutes = [
        "rss.xml.ts", "atom.xml.ts", "feed.json.ts",
        "articles/rss.xml.ts", "articles/atom.xml.ts", "articles/feed.json.ts",
        "tags/index.astro", "tags/[tag]/index.astro",
    ]

    @Test("every template route that lists articles is replaced by one that renders from EmDash")
    func articleListingRoutesRenderOnRequest() throws {
        let pages = Self.overlay.appendingPathComponent("src/pages")
        for route in Self.articleListingRoutes + ["sitemap-articles.xml.ts"] {
            let source = try String(contentsOf: pages.appendingPathComponent(route), encoding: .utf8)
            #expect(source.contains("export const prerender = false;"), "\(route) must render on request")
            #expect(source.contains("../lib/article-sources.ts"), "\(route) must read EmDash's articles")
            #expect(source.contains("articleCacheOptions("), "\(route) must carry EmDash's cache tags")
        }
        for route in Self.articleListingRoutes {
            #expect(FileManager.default.fileExists(
                atPath: Self.template.appendingPathComponent("src/pages/\(route)").path),
                "the template has no \(route) for the overlay to replace")
        }
        // The sitemap index and the page sitemap list no articles, so they stay prerendered.
        for route in ["sitemap.xml.ts", "sitemap-pages.xml.ts"] {
            let source = try String(contentsOf: pages.appendingPathComponent(route), encoding: .utf8)
            #expect(!source.contains("prerender = false"), "\(route) should be prerendered")
        }
    }

    @Test("the overlay's config captures the site files a Worker-rendered page reads")
    func configBundlesSiteFiles() throws {
        let config = try String(contentsOf: Self.overlay.appendingPathComponent("astro.config.ts"), encoding: .utf8)
        #expect(config.contains(#"__ANGLESITE_SITE_CONFIG__: siteFile(".site-config")"#))
        #expect(config.contains(#"__ANGLESITE_UTM_CODES__: siteFile("utm-codes.json")"#))
        let siteConfig = try String(contentsOf: Self.template.appendingPathComponent("scripts/config.ts"), encoding: .utf8)
        #expect(siteConfig.contains("__ANGLESITE_SITE_CONFIG__"))
        let utm = try String(contentsOf: Self.template.appendingPathComponent("src/lib/utm-codes.ts"), encoding: .utf8)
        #expect(utm.contains("__ANGLESITE_UTM_CODES__"))
    }
}
