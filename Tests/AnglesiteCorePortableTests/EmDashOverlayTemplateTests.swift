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
}
