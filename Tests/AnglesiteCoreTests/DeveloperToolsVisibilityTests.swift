import Testing
@testable import AnglesiteCore

/// The Settings ▸ Advanced "Show developer tools" gate (#1964, decision D1): every code-level
/// surface hides behind the one opt-in, and — unlike `DebugPaneVisibility` — nothing reveals it
/// in Debug builds, so a Debug build shows the owner's default.
@Suite("DeveloperToolsVisibility") struct DeveloperToolsVisibilityTests {
    @Test("everything technical is hidden by default")
    func hiddenByDefault() {
        let visibility = DeveloperToolsVisibility(settingEnabled: false)
        #expect(!visibility.showsCodeEditors)
        #expect(!visibility.showsSafariBridgeSetup)
    }

    @Test("the opt-in reveals the code editors and the Safari bridge setup together")
    func optInRevealsEverything() {
        let visibility = DeveloperToolsVisibility(settingEnabled: true)
        #expect(visibility.showsCodeEditors)
        #expect(visibility.showsSafariBridgeSetup)
    }

    @Test("only the raw text editor requires developer tools")
    func onlyTextEditorIsGated() {
        #expect(DeveloperToolsVisibility.requiresDeveloperTools(.text))
        #expect(!DeveloperToolsVisibility.requiresDeveloperTools(.plist))
        #expect(!DeveloperToolsVisibility.requiresDeveloperTools(.markdown))
        #expect(!DeveloperToolsVisibility.requiresDeveloperTools(.component))
    }

    @Test("owner editors show regardless of the setting; the text editor only with it")
    func showsEditorFollowsTheGate() {
        let off = DeveloperToolsVisibility(settingEnabled: false)
        let on = DeveloperToolsVisibility(settingEnabled: true)
        for kind in [EditorKind.plist, .markdown, .component] {
            #expect(off.showsEditor(kind), "\(kind) is an owner surface")
            #expect(on.showsEditor(kind))
        }
        #expect(!off.showsEditor(.text))
        #expect(on.showsEditor(.text))
    }
}
