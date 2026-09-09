// Unit tests for ShellModel.overlayCandidates — the pure, no-I/O half of overlaySource's
// resolution logic (Flatpak packaging investigation, #567). `ShellModel` lives in
// AnglesiteLinuxCore (not the ANGLESITE_LINUX_SHELL=1-gated GTK executable) precisely so this
// target runs on the plain Linux CI leg — see Package.swift's comment on that target (#1968).
import Testing
@testable import AnglesiteLinuxCore

@Suite("ShellModel.overlayCandidates")
struct ShellModelOverlaySourceTests {
    @Test("env override wins over every other candidate")
    func envOverrideWinsFirst() {
        let candidates = ShellModel.overlayCandidates(environment: [
            "ANGLESITE_OVERLAY_JS": "/custom/overlay.js",
            "FLATPAK_ID": "io.dwk.anglesite.linux",
        ])
        #expect(candidates.first == "/custom/overlay.js")
    }

    @Test("outside a Flatpak sandbox, the /app path is never a candidate")
    func flatpakPathAbsentOutsideSandbox() {
        let candidates = ShellModel.overlayCandidates(environment: [:])
        #expect(!candidates.contains("/app/share/anglesite/edit-overlay/overlay.js"))
        #expect(candidates == ["Resources/edit-overlay/overlay.js"])
    }

    @Test("inside a Flatpak sandbox, the /app path is tried before the dev-relative fallback")
    func flatpakPathPrecedesDevFallback() {
        let candidates = ShellModel.overlayCandidates(environment: ["FLATPAK_ID": "io.dwk.anglesite.linux"])
        #expect(candidates == [
            "/app/share/anglesite/edit-overlay/overlay.js",
            "Resources/edit-overlay/overlay.js",
        ])
    }

    static let nonOverridingEnvironments: [[String: String]] = [
        [:], ["FLATPAK_ID": "x"], ["ANGLESITE_OVERLAY_JS": "/y"],
    ]

    @Test("the dev-relative fallback is always present, last", arguments: nonOverridingEnvironments)
    func devFallbackAlwaysPresentLast(environment: [String: String]) {
        #expect(ShellModel.overlayCandidates(environment: environment).last == "Resources/edit-overlay/overlay.js")
    }
}
