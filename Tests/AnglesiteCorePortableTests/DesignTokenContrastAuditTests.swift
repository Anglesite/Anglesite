// Design-time contrast findings for theme tokens (#2021). Portable target: the audit and the
// wizard model are pure Foundation/Observation, so these run on the Linux CI leg as well as macOS.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DesignTokenContrastAudit (#2021)")
struct DesignTokenContrastAuditTests {

    /// The template's own light palette, read from `global.css`'s first `:root` block.
    static func templateDefaultPalette() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("Resources/Template/src/styles/global.css"), encoding: .utf8)
        let block = try #require(css.range(of: ":root {").map { css[$0.upperBound...] }?.split(separator: "}").first)
        var vars: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("--") else { continue }
            vars[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        }
        return vars
    }

    static let clean: [String: String] = [
        "color-primary": "#2563eb", "color-accent": "#f59e0b", "color-background": "#ffffff",
        "color-surface": "#f8fafc", "color-text": "#1e293b", "color-text-muted": "#64748b",
    ]

    static func finding(_ findings: [DesignTokenContrastFinding], _ fg: String, _ bg: String) -> DesignTokenContrastFinding? {
        findings.first { $0.pair.foregroundToken == fg && $0.pair.backgroundToken == bg }
    }

    // MARK: - What gets flagged

    @Test("the template's default palette produces no findings")
    func defaultPaletteIsClean() throws {
        let palette = try Self.templateDefaultPalette()
        #expect(palette["--color-text"] == "#1e293b")  // the parse really found the block
        #expect(DesignTokenContrastAudit.findings(for: palette).isEmpty)
    }

    @Test("every built-in theme is readable as shipped")
    func builtInThemesAreClean() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try ThemeCatalog.load(templateURL: root.appendingPathComponent("Resources/Template"))
        #expect(!catalog.themes.isEmpty)
        for theme in catalog.themes {
            let findings = DesignTokenContrastAudit.findings(for: DesignTokenWriter.templateCSSVars(for: theme))
            #expect(findings.isEmpty, "\(theme.id): \(findings.map(\.pair.place))")
        }
    }

    @Test("a pastel primary makes the link and button pairings findings")
    func pastelPrimary() throws {
        var vars = Self.clean
        vars["color-primary"] = "#a5d8ff"  // ~1.5:1 on white
        let findings = DesignTokenContrastAudit.findings(for: vars)
        let links = try #require(Self.finding(findings, "color-primary", "color-background"))
        #expect(links.severity == .error)  // below 3:1
        #expect(links.ratio < 3)
        #expect(Self.finding(findings, "color-background", "color-primary")?.severity == .error)
        #expect(Self.finding(findings, "color-primary", "color-surface") != nil)
        #expect(Self.finding(findings, "color-text", "color-background") == nil)
    }

    @Test("a link between 3:1 and 4.5:1 is a warning; text in that range is an error")
    func severityMapping() throws {
        var vars = Self.clean
        vars["color-primary"] = "#3b82f6"   // ~3.7:1 on white
        vars["color-text-muted"] = "#8a94a6" // ~3.1:1 on white
        let findings = DesignTokenContrastAudit.findings(for: vars)
        let links = try #require(Self.finding(findings, "color-primary", "color-background"))
        #expect(links.ratio >= 3 && links.ratio < 4.5)
        #expect(links.severity == .warning)
        let muted = try #require(Self.finding(findings, "color-text-muted", "color-background"))
        #expect(muted.ratio >= 3 && muted.ratio < 4.5)
        #expect(muted.severity == .error)
        #expect(muted.requiredRatio == 4.5)
    }

    @Test("a map without --color-surface produces no card findings and doesn't crash")
    func missingSurface() {
        var vars = Self.clean
        vars["color-surface"] = nil
        vars["color-text"] = "#cccccc"
        let findings = DesignTokenContrastAudit.findings(for: vars)
        #expect(!findings.isEmpty)
        #expect(!findings.contains { $0.pair.backgroundToken == "color-surface" })
    }

    @Test("unparseable tokens are skipped silently, and --color-accent is never checked")
    func skipsUnparseableAndAccent() {
        var vars = Self.clean
        vars["color-text"] = "var(--brand-ink)"
        vars["color-accent"] = "#ffffff"
        vars["color-text-muted"] = "rgb(0 0 0)"
        #expect(DesignTokenContrastAudit.findings(for: vars).isEmpty)
    }

    @Test("keys with the leading -- are read the same as bare keys")
    func acceptsDashedKeys() {
        let dashed = Dictionary(uniqueKeysWithValues: Self.clean.map { ("--\($0.key)", $0.value) })
            .merging(["--color-primary": "#a5d8ff"]) { _, new in new }
        #expect(DesignTokenContrastAudit.findings(for: dashed).count == 3)
    }

    // MARK: - Fixing

    @Test("a fix passes the threshold, keeps the background, and is idempotent")
    func fixIsIdempotent() throws {
        var vars = Self.clean
        vars["color-text-muted"] = "#b0b8c4"
        let finding = try #require(Self.finding(DesignTokenContrastAudit.findings(for: vars), "color-text-muted", "color-background"))
        let fixed = DesignTokenContrastAudit.applyingFix(finding, to: vars)
        #expect(fixed["color-background"] == vars["color-background"])
        #expect(WCAGContrast.contrastRatio(try #require(fixed["color-text-muted"]), "#ffffff") >= 4.5)
        #expect(Self.finding(DesignTokenContrastAudit.findings(for: fixed), "color-text-muted", "color-background") == nil)
        #expect(DesignTokenContrastAudit.applyingFix(finding, to: fixed) == fixed)
    }

    @Test("the button-label fix changes the primary colour, never the site background")
    func buttonFixKeepsBackground() throws {
        var vars = Self.clean
        vars["color-primary"] = "#a5d8ff"
        let button = try #require(Self.finding(DesignTokenContrastAudit.findings(for: vars), "color-background", "color-primary"))
        #expect(button.pair.adjustedToken == "color-primary")
        let fixed = DesignTokenContrastAudit.applyingFix(button, to: vars)
        #expect(fixed["color-background"] == "#ffffff")
        #expect(fixed["color-primary"] != "#a5d8ff")
        #expect(Self.finding(DesignTokenContrastAudit.findings(for: fixed), "color-background", "color-primary") == nil)
    }

    @Test("fix all clears every fixable finding, including a token used in two pairings")
    func fixAll() {
        var vars = Self.clean
        vars["color-primary"] = "#a5d8ff"
        vars["color-text"] = "#9aa5b1"
        vars["color-surface"] = "#eef2f6"
        let fixed = DesignTokenContrastAudit.applyingAllFixes(to: vars)
        #expect(DesignTokenContrastAudit.findings(for: fixed).isEmpty)
        #expect(fixed["color-background"] == vars["color-background"])
        #expect(fixed["color-surface"] == vars["color-surface"])
    }

    @Test("a fix keeps the key's original spelling")
    func fixKeepsKeySpelling() throws {
        let vars = ["--color-text": "#dddddd", "--color-background": "#ffffff"]
        let finding = try #require(DesignTokenContrastAudit.findings(for: vars).first)
        let fixed = DesignTokenContrastAudit.applyingFix(finding, to: vars)
        #expect(Set(fixed.keys) == Set(vars.keys))
    }

    @Test("with no reachable colour there's no suggestion, and applying it changes nothing")
    func unfixable() throws {
        // #777777 is dark enough that suggestReadable lightens, but even white only reaches
        // 4.48:1 on it — no adjustment of the text colour gets to 4.5:1.
        #expect(WCAGContrast.contrastRatio("#ffffff", "#777777") < 4.5)
        let vars = ["color-text": "#7a7a7a", "color-background": "#777777"]
        let finding = try #require(DesignTokenContrastAudit.findings(for: vars).first)
        #expect(finding.suggestedValue == nil)
        #expect(DesignTokenContrastAudit.applyingFix(finding, to: vars) == vars)
    }
}

@Suite("ThemeApplyWizardModel contrast findings (#2021)")
struct ThemeApplyWizardModelContrastTests {
    private static let catalog = ThemeCatalog(themes: [
        Theme(id: "pastel", name: "Pastel", blurb: "soft", swatch: [], cssVars: [
            "color-primary": "#a5d8ff", "color-background": "#ffffff", "color-text": "#1e293b",
        ]),
        Theme(id: "clean", name: "Clean", blurb: "crisp", swatch: [], cssVars: DesignTokenContrastAuditTests.clean),
    ])

    @MainActor
    private static func model() -> ThemeApplyWizardModel {
        let package = AnglesitePackage(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = ThemeApplyWizardModel(catalog: catalog, businessType: "bakery", package: package)
        model.source = .builtIn
        return model
    }

    @Test("findings follow the selected theme") @MainActor
    func findingsFollowSelection() {
        let model = Self.model()
        #expect(model.contrastFindings.isEmpty)
        model.selectedBuiltInID = "pastel"
        #expect(model.contrastFindings.map(\.pair.place) == ["Links", "Button labels"])
        model.selectedBuiltInID = "clean"
        #expect(model.contrastFindings.isEmpty)
    }

    @Test("fixing one finding overrides just that token, and the audit re-runs") @MainActor
    func fixOne() throws {
        let model = Self.model()
        model.selectedBuiltInID = "pastel"
        let links = try #require(model.contrastFindings.first)
        model.fixContrast(links)
        #expect(Array(model.tokenOverrides.keys) == ["color-primary"])
        #expect(model.effectiveCSSVars["color-background"] == "#ffffff")
        // Both pairings compare the same two colours, so fixing links fixes buttons too.
        #expect(model.contrastFindings.isEmpty)
    }

    @Test("fix all, then switching themes discards the fixes") @MainActor
    func fixAllThenSwitch() {
        let model = Self.model()
        model.selectedBuiltInID = "pastel"
        model.fixAllContrast()
        #expect(model.contrastFindings.isEmpty)
        #expect(!model.tokenOverrides.isEmpty)
        model.selectedBuiltInID = "clean"
        #expect(model.tokenOverrides.isEmpty)
        model.selectedBuiltInID = "pastel"
        #expect(!model.contrastFindings.isEmpty)
    }

    @Test("the freedesignmd path has no tokens and so no findings") @MainActor
    func freedesignmdHasNoFindings() {
        let model = Self.model()
        model.selectedBuiltInID = "pastel"
        model.source = .freedesignmd
        #expect(model.effectiveCSSVars.isEmpty)
        #expect(model.contrastFindings.isEmpty)
    }
}
