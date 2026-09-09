// Unit tests for ShellModel.engineCandidates — the pure, no-I/O half of engineSource's
// resolution logic (Flatpak packaging investigation, #567). Split into its own testTarget
// because AnglesiteLinux is only in the package graph under ANGLESITE_LINUX_SHELL=1 (see
// Package.swift's gating comment) — this file needs none of the GTK/Adwaita toolchain that
// gate exists for, but @testable import AnglesiteLinux still pulls in the whole target.
import Testing
@testable import AnglesiteLinux

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
