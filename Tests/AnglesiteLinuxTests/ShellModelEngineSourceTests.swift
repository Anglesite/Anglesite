// Unit tests for ShellModel.engineCandidates — the pure, no-I/O half of engineSource's
// resolution logic (Flatpak packaging investigation, #567). `ShellModel` lives in
// AnglesiteLinuxCore (not the ANGLESITE_LINUX_SHELL=1-gated GTK executable) precisely so this
// target runs on the plain Linux CI leg — see Package.swift's comment on that target (#1968).
import Testing
@testable import AnglesiteLinuxCore

@Suite("ShellModel.engineCandidates")
struct ShellModelEngineSourceTests {
    @Test("env override wins over every other candidate")
    func envOverrideWinsFirst() {
        let candidates = ShellModel.engineCandidates(environment: [
            "ANGLESITE_WYSIWYG_ENGINE_JS": "/custom/engine.js",
            "FLATPAK_ID": "io.dwk.anglesite.linux",
        ])
        #expect(candidates.first == "/custom/engine.js")
    }

    @Test("outside a Flatpak sandbox, the /app path is never a candidate")
    func flatpakPathAbsentOutsideSandbox() {
        let candidates = ShellModel.engineCandidates(environment: [:])
        #expect(!candidates.contains("/app/share/anglesite/wysiwyg-engine/engine.js"))
        #expect(candidates == ["Resources/wysiwyg-engine/engine.js"])
    }

    @Test("inside a Flatpak sandbox, the /app path is tried before the dev-relative fallback")
    func flatpakPathPrecedesDevFallback() {
        let candidates = ShellModel.engineCandidates(environment: ["FLATPAK_ID": "io.dwk.anglesite.linux"])
        #expect(candidates == [
            "/app/share/anglesite/wysiwyg-engine/engine.js",
            "Resources/wysiwyg-engine/engine.js",
        ])
    }

    static let nonOverridingEnvironments: [[String: String]] = [
        [:], ["FLATPAK_ID": "x"], ["ANGLESITE_WYSIWYG_ENGINE_JS": "/y"],
    ]

    @Test("the dev-relative fallback is always present, last", arguments: nonOverridingEnvironments)
    func devFallbackAlwaysPresentLast(environment: [String: String]) {
        #expect(ShellModel.engineCandidates(environment: environment).last == "Resources/wysiwyg-engine/engine.js")
    }
}
