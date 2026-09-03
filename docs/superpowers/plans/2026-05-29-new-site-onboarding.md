# New Site Onboarding Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native, no-Claude "New Site" wizard that collects type + name + theme + first content, scaffolds a site deterministically, applies a built-in theme and pre-fills the homepage, then opens it to a live preview — working identically in the Developer-ID and Mac App Store builds.

**Architecture:** A thin SwiftUI wizard collects a `NewSiteDraft`. A `SiteScaffolder` actor runs the pipeline (mkdir → `scaffold.sh` → write `.site-config` → apply theme → write homepage → `npm install` → register) and emits an `AsyncStream<ScaffoldStep>` the wizard renders. Theme data is parsed at runtime from the bundled plugin's `template/scripts/themes.ts` (`ThemeCatalog`); applying a theme (`ThemeApplier`) and pre-filling content (`HomepageWriter`) are pure string transforms over known template files. The launcher presents the wizard and opens the site on completion.

**Tech Stack:** Swift 6 / SwiftUI, `AnglesiteCore` (actors + pure helpers), `ProcessSupervisor` for subprocesses, XCTest. Spec: `docs/superpowers/specs/2026-05-29-new-site-onboarding-design.md`.

---

## File Structure

**New files (`Sources/AnglesiteCore/`):**
- `NewSiteDraft.swift` — `SiteType` enum, `NewSiteDraft` value, `SiteSlug` deriver.
- `ThemeCatalog.swift` — `Theme` value, parse `themes.ts`, `defaultThemeID(for:)`.
- `ThemeApplier.swift` — rewrite `:root` custom properties in `global.css`.
- `HomepageWriter.swift` — rewrite title/description/h1/intro in `index.astro`.
- `SiteScaffolder.swift` — `ScaffoldStep`, the pipeline actor, injectable `CommandRunner` + `register` hook.

- `NewSiteWizardModel.swift` (`Sources/AnglesiteCore/`) — `@MainActor @Observable` model: step state, validation, runs the scaffolder. Lives in `AnglesiteCore` alongside `HealthModel` (both use `import Observation`, no SwiftUI).

**New files (`Sources/AnglesiteApp/`):**
- `NewSiteWizard.swift` — the SwiftUI sheet (thin views per step).

**New test files (`Tests/AnglesiteCoreTests/`):**
- `SiteSlugTests.swift`, `ThemeCatalogTests.swift`, `ThemeApplierTests.swift`, `HomepageWriterTests.swift`, `SiteScaffolderTests.swift`, `NewSiteWizardModelTests.swift`.

**Modified:**
- `Sources/AnglesiteApp/SitesLauncherView.swift` — replace the disabled "New Site…" label with a live button + sheet presentation + open-on-done.
- `Sources/AnglesiteCore/AppSettings.swift` — add `sitesRootBookmark: Data?` (MAS sites-root grant).

> Module placement confirmed: `HealthModel` (an `@MainActor @Observable`) lives in `AnglesiteCore` and `HealthModelTests` in `AnglesiteCoreTests`. `NewSiteWizardModel` follows that exactly; only the SwiftUI `View` lives in `AnglesiteApp`.

---

## Task 1: SiteType, NewSiteDraft, and slug derivation

**Files:**
- Create: `Sources/AnglesiteCore/NewSiteDraft.swift`
- Test: `Tests/AnglesiteCoreTests/SiteSlugTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

final class SiteSlugTests: XCTestCase {
    func testLowercasesAndHyphenates() {
        XCTAssertEqual(SiteSlug.derive(from: "Blue Bottle Cafe"), "blue-bottle-cafe")
    }
    func testStripsPunctuationAndCollapsesHyphens() {
        XCTAssertEqual(SiteSlug.derive(from: "  Hello!!   World  "), "hello-world")
    }
    func testFoldsDiacritics() {
        XCTAssertEqual(SiteSlug.derive(from: "Café Niño"), "cafe-nino")
    }
    func testEmptyFallsBackToUntitled() {
        XCTAssertEqual(SiteSlug.derive(from: "   "), "untitled-site")
    }
    func testDraftDefaultsHeadlineFromName() {
        let d = NewSiteDraft(siteType: .business, name: "Acme")
        XCTAssertEqual(d.headline, "Acme")
        XCTAssertEqual(d.themeID, "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SiteSlugTests`
Expected: FAIL — `cannot find 'SiteSlug' in scope` / `'NewSiteDraft'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The kind of site the owner is creating. The wizard collects only these five broad
/// categories; the plugin's fine-grained `bestFor` business types stay with the chat path.
public enum SiteType: String, Sendable, CaseIterable, Codable {
    case business, personal, blog, portfolio, organization

    /// Owner-facing label for the Type step.
    public var label: String {
        switch self {
        case .business:     return "Business"
        case .personal:     return "Personal"
        case .blog:         return "Blog"
        case .portfolio:    return "Portfolio"
        case .organization: return "Organization"
        }
    }

    /// SF Symbol for the Type step row.
    public var symbol: String {
        switch self {
        case .business:     return "building.2"
        case .personal:     return "person.crop.circle"
        case .blog:         return "text.alignleft"
        case .portfolio:    return "square.grid.2x2"
        case .organization: return "person.3"
        }
    }
}

/// Everything the wizard collects before scaffolding. A plain value — no behavior.
public struct NewSiteDraft: Sendable, Equatable {
    public var siteType: SiteType
    public var name: String
    public var tagline: String
    public var themeID: String
    public var headline: String
    public var blurb: String

    public init(
        siteType: SiteType,
        name: String,
        tagline: String = "",
        themeID: String = "",
        headline: String? = nil,
        blurb: String = ""
    ) {
        self.siteType = siteType
        self.name = name
        self.tagline = tagline
        self.themeID = themeID
        // Default the homepage headline to the site name so step 4 starts pre-filled.
        self.headline = headline ?? name
        self.blurb = blurb
    }
}

/// Derives a filesystem-safe folder slug from a site name.
public enum SiteSlug {
    public static func derive(from name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: .current)
        var out = ""
        var lastWasHyphen = false
        for scalar in folded.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled-site" : trimmed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SiteSlugTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/NewSiteDraft.swift Tests/AnglesiteCoreTests/SiteSlugTests.swift
git commit -m "feat(onboarding): SiteType, NewSiteDraft, and slug derivation"
```

---

## Task 2: ThemeCatalog — parse themes.ts + default mapping

**Files:**
- Create: `Sources/AnglesiteCore/ThemeCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/ThemeCatalogTests.swift`

Background: the plugin ships `template/scripts/themes.ts` exporting `THEMES: Record<string, Theme>`. Each entry has, **in this field order**, `displayName: "..."`, `description: "..."`, `bestFor: [...]`, then `vars: { "color-primary": "#...", ..., "font-body": "..." }`. `vars` contains no `}` until it closes, and `bestFor` no `]` until it closes, so a per-theme regex anchored on that order is robust. The drift-guard test (below) fails loudly if the plugin ever restructures the file.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

final class ThemeCatalogTests: XCTestCase {

    // A trimmed fixture mirroring the real themes.ts shape (two themes, varied fonts).
    private let fixture = """
    export const THEMES: Record<string, Theme> = {
      classic: {
        displayName: "Classic",
        description: "Traditional, trustworthy, professional",
        bestFor: ["legal", "finance"],
        vars: {
          "color-primary": "#1e3a5f",
          "color-accent": "#c8a951",
          "font-heading": "Georgia, 'Times New Roman', serif",
          "font-body": "system-ui, -apple-system, sans-serif",
        },
      },
      studio: {
        displayName: "Studio",
        description: "Dark mode for creative coders",
        bestFor: ["generative-art"],
        vars: {
          "color-primary": "#00ff88",
          "color-accent": "#00ff88",
          "font-heading": "monospace",
          "font-body": "monospace",
        },
      },
    };
    """

    func testParsesThemesInOrder() throws {
        let themes = try ThemeCatalog.parse(themesTS: fixture)
        XCTAssertEqual(themes.map(\.id), ["classic", "studio"])
        XCTAssertEqual(themes[0].name, "Classic")
        XCTAssertEqual(themes[0].blurb, "Traditional, trustworthy, professional")
        XCTAssertEqual(themes[0].cssVars["color-primary"], "#1e3a5f")
        // Font value with embedded commas + single quotes survives intact.
        XCTAssertEqual(themes[0].cssVars["font-heading"], "Georgia, 'Times New Roman', serif")
        XCTAssertEqual(themes[0].swatch, ["#1e3a5f", "#c8a951"])
    }

    func testDefaultThemeIDResolvesForEverySiteType() throws {
        let catalog = ThemeCatalog(themes: try ThemeCatalog.parse(themesTS: fixture))
        for type in SiteType.allCases {
            let id = catalog.defaultThemeID(for: type)
            XCTAssertNotNil(catalog.theme(id: id), "no theme for \(type)")
        }
    }

    // DRIFT GUARD: parse the REAL bundled plugin themes.ts. Skips when the sibling
    // plugin checkout isn't present (e.g. CI without it / pure `swift test`).
    func testRealThemesFileParsesToEightCompleteThemes() throws {
        guard let url = Self.realThemesURL(), let ts = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("plugin themes.ts not found; set ANGLESITE_PLUGIN_PATH or check out ../anglesite")
        }
        let themes = try ThemeCatalog.parse(themesTS: ts)
        XCTAssertEqual(themes.count, 8, "expected 8 built-in themes (data file ships 8; SKILL.md prose says 9)")
        for t in themes {
            for key in ["color-primary", "color-accent", "font-heading", "font-body"] {
                XCTAssertNotNil(t.cssVars[key], "\(t.id) missing --\(key)")
            }
        }
        let catalog = ThemeCatalog(themes: themes)
        for type in SiteType.allCases {
            XCTAssertNotNil(catalog.theme(id: catalog.defaultThemeID(for: type)))
        }
    }

    /// Resolve the real themes.ts via env override or the sibling repo relative to this source file.
    static func realThemesURL() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"] {
            let u = URL(fileURLWithPath: env)
                .appendingPathComponent("template/scripts/themes.ts")
            if fm.fileExists(atPath: u.path) { return u }
        }
        // <repo>/Tests/AnglesiteCoreTests/ThemeCatalogTests.swift -> repo root is 3 up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sibling = repoRoot.deletingLastPathComponent()
            .appendingPathComponent("anglesite/template/scripts/themes.ts")
        return fm.fileExists(atPath: sibling.path) ? sibling : nil
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ThemeCatalogTests`
Expected: FAIL — `cannot find 'ThemeCatalog' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One built-in visual theme, parsed from the plugin's `template/scripts/themes.ts`.
public struct Theme: Sendable, Identifiable, Equatable {
    public let id: String                    // THEMES record key, e.g. "warm"
    public let name: String                  // displayName
    public let blurb: String                 // description
    public let swatch: [String]              // [color-primary, color-accent] for the gallery
    public let cssVars: [String: String]     // vars: custom-property name (no leading --) -> value

    public init(id: String, name: String, blurb: String, swatch: [String], cssVars: [String: String]) {
        self.id = id; self.name = name; self.blurb = blurb; self.swatch = swatch; self.cssVars = cssVars
    }
}

/// The 8 built-in themes plus the wizard's default-by-site-type mapping.
public struct ThemeCatalog: Sendable {
    public let themes: [Theme]
    public init(themes: [Theme]) { self.themes = themes }

    public enum ParseError: Error, Sendable, Equatable { case noThemesDeclaration }

    public func theme(id: String) -> Theme? { themes.first { $0.id == id } }

    /// App-side default theme per broad site type. Falls back to the first available theme
    /// if the preferred id isn't present (keeps the drift guard meaningful).
    public func defaultThemeID(for type: SiteType) -> String {
        let preferred: [SiteType: String] = [
            .business: "classic", .personal: "elegant", .blog: "warm",
            .portfolio: "bold", .organization: "community",   // no "studio" in the data file
        ]
        let want = preferred[type] ?? "classic"
        if theme(id: want) != nil { return want }
        return themes.first?.id ?? want
    }

    /// Load + parse the bundled plugin's themes.ts. `pluginURL` is the plugin root
    /// (`PluginRuntime.resolve().url`); themes.ts lives at template/scripts/themes.ts.
    public static func load(pluginURL: URL) throws -> ThemeCatalog {
        let url = pluginURL.appendingPathComponent("template/scripts/themes.ts")
        let ts = try String(contentsOf: url, encoding: .utf8)
        return ThemeCatalog(themes: try parse(themesTS: ts))
    }

    /// Tolerant parser keyed on the known field order (displayName, description, bestFor, vars).
    public static func parse(themesTS: String) throws -> [Theme] {
        guard themesTS.contains("THEMES") else { throw ParseError.noThemesDeclaration }

        // Per-theme block: id, displayName, description, bestFor[...], vars{...}.
        // `vars` body uses [^}]* — safe because vars holds no nested braces.
        let themePattern = #"(\w+):\s*\{\s*displayName:\s*"([^"]*)",\s*description:\s*"([^"]*)",\s*bestFor:\s*\[[^\]]*\],\s*vars:\s*\{([^}]*)\}"#
        let varPattern = #""([^"]+)":\s*"([^"]*)""#

        let themeRE = try NSRegularExpression(pattern: themePattern, options: [.dotMatchesLineSeparators])
        let varRE = try NSRegularExpression(pattern: varPattern, options: [])

        let ns = themesTS as NSString
        var result: [Theme] = []
        for m in themeRE.matches(in: themesTS, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let blurb = ns.substring(with: m.range(at: 3))
            let varsBody = ns.substring(with: m.range(at: 4))

            var vars: [String: String] = [:]
            let vns = varsBody as NSString
            for vm in varRE.matches(in: varsBody, range: NSRange(location: 0, length: vns.length)) {
                vars[vns.substring(with: vm.range(at: 1))] = vns.substring(with: vm.range(at: 2))
            }
            let swatch = ["color-primary", "color-accent"].compactMap { vars[$0] }
            result.append(Theme(id: id, name: name, blurb: blurb, swatch: swatch, cssVars: vars))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ThemeCatalogTests`
Expected: PASS. The drift-guard test PASSES if `../anglesite` is present, else SKIPS — both are green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ThemeCatalog.swift Tests/AnglesiteCoreTests/ThemeCatalogTests.swift
git commit -m "feat(onboarding): ThemeCatalog parses themes.ts with drift guard"
```

---

## Task 3: ThemeApplier — rewrite :root custom properties

**Files:**
- Create: `Sources/AnglesiteCore/ThemeApplier.swift`
- Test: `Tests/AnglesiteCoreTests/ThemeApplierTests.swift`

Background: `template/src/styles/global.css` declares custom properties as `--color-primary: #2563eb;` inside `:root { ... }`. The theme's `cssVars` keys (`color-primary`, `font-heading`, …) map to `--<key>`. We rewrite only the values for keys the theme provides; spacing/radius/shadow lines (no matching key) are untouched.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

final class ThemeApplierTests: XCTestCase {
    private let css = """
    :root {
      --color-primary: #2563eb;
      --color-accent: #d97706;
      --font-heading: system-ui, -apple-system, sans-serif;
      --font-body: system-ui, -apple-system, sans-serif;
      --space-md: 1rem;
      --radius-sm: 4px;
    }
    """
    private let theme = Theme(
        id: "warm", name: "Warm", blurb: "",
        swatch: [],
        cssVars: [
            "color-primary": "#e65100",
            "color-accent": "#c62828",
            "font-heading": "Georgia, 'Times New Roman', serif",
            "font-body": "system-ui, sans-serif",
        ]
    )

    func testReplacesProvidedPropertiesOnly() {
        let out = ThemeApplier.apply(theme, toCSS: css)
        XCTAssertTrue(out.contains("--color-primary: #e65100;"))
        XCTAssertTrue(out.contains("--color-accent: #c62828;"))
        XCTAssertTrue(out.contains("--font-heading: Georgia, 'Times New Roman', serif;"))
        // Untouched, no matching cssVars key:
        XCTAssertTrue(out.contains("--space-md: 1rem;"))
        XCTAssertTrue(out.contains("--radius-sm: 4px;"))
    }

    func testIsIdempotent() {
        let once = ThemeApplier.apply(theme, toCSS: css)
        let twice = ThemeApplier.apply(theme, toCSS: once)
        XCTAssertEqual(once, twice)
    }

    func testWritesFileInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cssPath = dir.appendingPathComponent("src/styles/global.css")
        try FileManager.default.createDirectory(at: cssPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try css.write(to: cssPath, atomically: true, encoding: .utf8)
        try ThemeApplier.apply(theme, siteDirectory: dir)
        let out = try String(contentsOf: cssPath, encoding: .utf8)
        XCTAssertTrue(out.contains("--color-primary: #e65100;"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ThemeApplierTests`
Expected: FAIL — `cannot find 'ThemeApplier' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Applies a `Theme` to a site's `src/styles/global.css` by rewriting the values of the
/// `--<key>` custom properties the theme provides. Properties without a matching theme key
/// (spacing, radius, shadows, type scale) are left untouched. Pure + idempotent.
public enum ThemeApplier {
    public enum ApplyError: Error, Sendable { case cssNotFound(URL) }

    public static func apply(_ theme: Theme, toCSS css: String) -> String {
        var result = css
        for (key, value) in theme.cssVars {
            // Match `--key:` then everything up to the line-ending `;`, replace the value.
            let pattern = "(--" + NSRegularExpression.escapedPattern(for: key) + ":)[^;\\n]*;"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            // `$1` keeps `--key:`; template is literal so escape backslashes/$ in the value.
            let safeValue = value.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "$", with: "\\$")
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "$1 " + safeValue + ";"
            )
        }
        return result
    }

    public static func apply(_ theme: Theme, siteDirectory: URL, fileManager: FileManager = .default) throws {
        let cssURL = siteDirectory.appendingPathComponent("src/styles/global.css")
        guard let css = try? String(contentsOf: cssURL, encoding: .utf8) else {
            throw ApplyError.cssNotFound(cssURL)
        }
        let updated = apply(theme, toCSS: css)
        try updated.write(to: cssURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ThemeApplierTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ThemeApplier.swift Tests/AnglesiteCoreTests/ThemeApplierTests.swift
git commit -m "feat(onboarding): ThemeApplier rewrites global.css custom properties"
```

---

## Task 4: HomepageWriter — pre-fill index.astro

**Files:**
- Create: `Sources/AnglesiteCore/HomepageWriter.swift`
- Test: `Tests/AnglesiteCoreTests/HomepageWriterTests.swift`

Background: the scaffolded `src/pages/index.astro` ships exactly:
```
  title="Welcome — Your New Anglesite Business Website"
  description="Your business website is ready to set up. Run /start in Claude to begin the guided setup."
...
  <h1>Welcome</h1>
  <p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>
```
We replace these known strings. `title` ← headline; `description` ← blurb (else tagline, else default); `<h1>` ← headline; intro `<p>` ← blurb (only if blurb non-empty). Attribute values escape `"` and `&`; markup text escapes `<`, `>`, `&`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

final class HomepageWriterTests: XCTestCase {
    private let astro = """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout
      title="Welcome — Your New Anglesite Business Website"
      description="Your business website is ready to set up. Run /start in Claude to begin the guided setup."
    >
      <h1>Welcome</h1>
      <p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>
    </BaseLayout>
    """

    func testFillsHeadlineAndBlurb() {
        let out = HomepageWriter.fill(astro, headline: "Blue Bottle", blurb: "Neighborhood coffee in Oakland.", tagline: "Coffee, slow-roasted.")
        XCTAssertTrue(out.contains(#"title="Blue Bottle""#))
        XCTAssertTrue(out.contains(#"description="Neighborhood coffee in Oakland.""#))
        XCTAssertTrue(out.contains("<h1>Blue Bottle</h1>"))
        XCTAssertTrue(out.contains("<p>Neighborhood coffee in Oakland.</p>"))
        XCTAssertFalse(out.contains("/start"))
    }

    func testEmptyBlurbLeavesIntroDefaultAndUsesTaglineForDescription() {
        let out = HomepageWriter.fill(astro, headline: "Acme", blurb: "", tagline: "We do things.")
        XCTAssertTrue(out.contains(#"description="We do things.""#))
        XCTAssertTrue(out.contains("<h1>Acme</h1>"))
        // Intro paragraph untouched when no blurb:
        XCTAssertTrue(out.contains("Type <code>/start</code>"))
    }

    func testEscapesAttributeAndMarkup() {
        let out = HomepageWriter.fill(astro, headline: "Tom & \"Jerry\"", blurb: "1 < 2 & 3", tagline: "")
        XCTAssertTrue(out.contains(#"title="Tom &amp; &quot;Jerry&quot;""#))
        XCTAssertTrue(out.contains("<h1>Tom &amp; &quot;Jerry&quot;</h1>"))
        XCTAssertTrue(out.contains("<p>1 &lt; 2 &amp; 3</p>"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HomepageWriterTests`
Expected: FAIL — `cannot find 'HomepageWriter' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pre-fills the scaffolded homepage (`src/pages/index.astro`) with the owner's headline and
/// blurb by replacing the known template strings. Operates on known content (safe targeted
/// replace, not a fuzzy patch).
public enum HomepageWriter {
    public enum WriteError: Error, Sendable { case homepageNotFound(URL) }

    // The exact strings the template ships.
    private static let titleLine =
        #"title="Welcome — Your New Anglesite Business Website""#
    private static let descLine =
        #"description="Your business website is ready to set up. Run /start in Claude to begin the guided setup.""#
    private static let h1Line = "<h1>Welcome</h1>"
    private static let introLine =
        "<p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>"

    public static func fill(_ source: String, headline: String, blurb: String, tagline: String) -> String {
        var out = source
        let h = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = blurb.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tagline.trimmingCharacters(in: .whitespacesAndNewlines)

        if !h.isEmpty {
            out = out.replacingOccurrences(of: titleLine, with: #"title=""# + attr(h) + #"""#)
            out = out.replacingOccurrences(of: h1Line, with: "<h1>" + markup(h) + "</h1>")
        }
        let description = !b.isEmpty ? b : t
        if !description.isEmpty {
            out = out.replacingOccurrences(of: descLine, with: #"description=""# + attr(description) + #"""#)
        }
        if !b.isEmpty {
            out = out.replacingOccurrences(of: introLine, with: "<p>" + markup(b) + "</p>")
        }
        return out
    }

    public static func write(headline: String, blurb: String, tagline: String,
                             siteDirectory: URL, fileManager: FileManager = .default) throws {
        let url = siteDirectory.appendingPathComponent("src/pages/index.astro")
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            throw WriteError.homepageNotFound(url)
        }
        try fill(src, headline: headline, blurb: blurb, tagline: tagline)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Escape for a double-quoted HTML attribute.
    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// Escape for HTML text content.
    private static func markup(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HomepageWriterTests`
Expected: PASS (3 tests). Note: `attr`/`markup` escape `&` first so later replacements don't double-encode.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HomepageWriter.swift Tests/AnglesiteCoreTests/HomepageWriterTests.swift
git commit -m "feat(onboarding): HomepageWriter pre-fills index.astro"
```

---

## Task 5: SiteScaffolder — the pipeline actor

**Files:**
- Create: `Sources/AnglesiteCore/SiteScaffolder.swift`
- Test: `Tests/AnglesiteCoreTests/SiteScaffolderTests.swift`

Background / real APIs to reuse:
- `ProcessSupervisor.shared.run(executable:arguments:environment:currentDirectoryURL:) async throws -> RunResult` (`.exitCode`, `.stdout`, `.stderr`).
- `scaffold.sh`: run `/bin/zsh <plugin>/scripts/scaffold.sh --yes <dir>`; `<plugin>` = `PluginRuntime.resolve().url`.
- `npm`: `node = NodeRuntime.bundledExecutableURL`; `npm = node/../npm`; run `node <npm> <NodeModulesCache.shared.npmInstallArguments()>` with cwd = site dir (mirrors `DeployCommand`'s build resolver).
- Registration: `SiteStore.shared.add(_:)` (injected so tests don't mutate shared state).

The scaffolder is injectable via a `CommandRunner` closure and a `register` closure for unit testing.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

final class SiteScaffolderTests: XCTestCase {

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeDraft() -> NewSiteDraft {
        NewSiteDraft(siteType: .business, name: "Acme Co", tagline: "We build.",
                     themeID: "classic", headline: "Acme", blurb: "Welcome to Acme.")
    }

    private let theme = Theme(id: "classic", name: "Classic", blurb: "", swatch: [],
                              cssVars: ["color-primary": "#1e3a5f"])

    /// A fake CommandRunner that records calls and simulates scaffold.sh by writing the
    /// template files the appliers expect.
    private func fakeRunner(scaffoldExit: Int32 = 0, npmExit: Int32 = 0,
                            calls: CallRecorder) -> SiteScaffolder.CommandRunner {
        return { executable, args, cwd in
            await calls.append(args.joined(separator: " "))
            if args.contains("scaffold.sh"), scaffoldExit == 0, let cwd {
                // Simulate the template copy the real scaffold.sh performs.
                let css = cwd.appendingPathComponent("src/styles/global.css")
                let astro = cwd.appendingPathComponent("src/pages/index.astro")
                try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? ":root {\n  --color-primary: #2563eb;\n}".write(to: css, atomically: true, encoding: .utf8)
                try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
            }
            let exit = args.contains("scaffold.sh") ? scaffoldExit : npmExit
            return ProcessSupervisor.RunResult(stdout: "", stderr: exit == 0 ? "" : "boom", exitCode: exit)
        }
    }

    func testHappyPathEmitsStepsInOrderAndRegisters() async throws {
        let root = tmpDir()
        let calls = CallRecorder()
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            pluginURL: URL(fileURLWithPath: "/plugin"),
            catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: calls),
            register: { url in SiteStore.Site(id: url.path, name: url.lastPathComponent, path: url, isValid: true, missingSentinels: []) }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        XCTAssertEqual(steps.first, .creatingFolder)
        if case .done(let id) = steps.last { XCTAssertEqual(id, root.appendingPathComponent("acme-co").path) }
        else { XCTFail("expected .done last, got \(String(describing: steps.last))") }
        // .site-config gained SITE_NAME without clobbering the stamped version.
        let cfg = try String(contentsOf: root.appendingPathComponent("acme-co/.site-config"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("ANGLESITE_VERSION=1.0.0"))
        XCTAssertTrue(cfg.contains("SITE_NAME=Acme Co"))
        // Theme + homepage applied:
        let css = try String(contentsOf: root.appendingPathComponent("acme-co/src/styles/global.css"), encoding: .utf8)
        XCTAssertTrue(css.contains("--color-primary: #1e3a5f;"))
    }

    func testScaffoldFailureIsFatal() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, pluginURL: URL(fileURLWithPath: "/plugin"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(scaffoldExit: 1, calls: CallRecorder()),
            register: { _ in XCTFail("must not register on scaffold failure"); fatalError() }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        guard case .failed(let step, _)? = steps.last else { return XCTFail("expected .failed") }
        XCTAssertEqual(step, "copyingTemplate")
    }

    func testNpmFailureIsNonFatalAndStillRegisters() async throws {
        let root = tmpDir()
        var registered = false
        let scaffolder = SiteScaffolder(
            sitesRoot: root, pluginURL: URL(fileURLWithPath: "/plugin"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(npmExit: 1, calls: CallRecorder()),
            register: { url in registered = true; return SiteStore.Site(id: url.path, name: "x", path: url, isValid: true, missingSentinels: []) }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        XCTAssertTrue(registered, "npm failure should not block registration")
        XCTAssertTrue(steps.contains { if case .warning(let s, _) = $0 { return s == "installing" }; return false })
        guard case .done? = steps.last else { return XCTFail("expected .done despite npm failure") }
    }
}

/// Tiny test helper: records command-runner calls behind an actor (no data race in @Sendable).
actor CallRecorder {
    private(set) var calls: [String] = []
    func append(_ s: String) { calls.append(s) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SiteScaffolderTests`
Expected: FAIL — `cannot find 'SiteScaffolder' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Runs the deterministic new-site pipeline and emits progress. No Claude. Every subprocess
/// goes through the injected `CommandRunner` (production: `ProcessSupervisor.shared.run`).
public actor SiteScaffolder {

    public enum ScaffoldStep: Sendable, Equatable {
        case creatingFolder, copyingTemplate, applyingTheme, writingContent, installing, registering
        case warning(step: String, message: String)
        case failed(step: String, message: String)
        case done(siteID: String)
    }

    /// Run a command, return its result. cwd may be nil.
    public typealias CommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult
    /// Register a freshly-scaffolded directory and return the Site (production: SiteStore.shared.add).
    public typealias Register = @Sendable (_ siteDirectory: URL) async throws -> SiteStore.Site

    private let sitesRoot: URL
    private let pluginURL: URL
    private let catalog: ThemeCatalog
    private let run: CommandRunner
    private let register: Register
    private let fileManager: FileManager

    /// `catalog` (not a fixed theme) so the owner's Look-step choice resolves at pipeline time
    /// from `draft.themeID`.
    public init(sitesRoot: URL, pluginURL: URL, catalog: ThemeCatalog,
                run: @escaping CommandRunner, register: @escaping Register,
                fileManager: FileManager = .default) {
        self.sitesRoot = sitesRoot
        self.pluginURL = pluginURL
        self.catalog = catalog
        self.run = run
        self.register = register
        self.fileManager = fileManager
    }

    public func scaffold(_ draft: NewSiteDraft) -> AsyncStream<ScaffoldStep> {
        AsyncStream { continuation in
            Task {
                await self.runPipeline(draft, emit: continuation.yield)
                continuation.finish()
            }
        }
    }

    private func runPipeline(_ draft: NewSiteDraft, emit: @Sendable (ScaffoldStep) -> Void) async {
        let slug = SiteSlug.derive(from: draft.name)
        let siteDir = sitesRoot.appendingPathComponent(slug, isDirectory: true)

        // 1. Folder
        emit(.creatingFolder)
        do { try fileManager.createDirectory(at: siteDir, withIntermediateDirectories: true) }
        catch { return emit(.failed(step: "creatingFolder", message: humanize(error))) }

        // 2. scaffold.sh
        emit(.copyingTemplate)
        let scaffoldScript = pluginURL.appendingPathComponent("scripts/scaffold.sh")
        do {
            let r = try await run(URL(fileURLWithPath: "/bin/zsh"),
                                  [scaffoldScript.path, "--yes", siteDir.path], siteDir)
            if r.exitCode != 0 {
                return emit(.failed(step: "copyingTemplate",
                                    message: "Couldn't create the site files.\n\(r.stderr)"))
            }
        } catch { return emit(.failed(step: "copyingTemplate", message: humanize(error))) }

        // 2b. Append owner answers to .site-config (scaffold.sh excludes it + stamps ANGLESITE_VERSION).
        appendSiteConfig(draft, siteDir: siteDir)

        // 3. Theme (non-fatal). Resolve the owner's chosen theme; fall back to the first available.
        emit(.applyingTheme)
        if let theme = catalog.theme(id: draft.themeID) ?? catalog.themes.first {
            do { try ThemeApplier.apply(theme, siteDirectory: siteDir, fileManager: fileManager) }
            catch { emit(.warning(step: "applyingTheme", message: humanize(error))) }
        } else {
            emit(.warning(step: "applyingTheme", message: "No themes available; left default look."))
        }

        // 4. Homepage (non-fatal)
        emit(.writingContent)
        do { try HomepageWriter.write(headline: draft.headline, blurb: draft.blurb,
                                      tagline: draft.tagline, siteDirectory: siteDir, fileManager: fileManager) }
        catch { emit(.warning(step: "writingContent", message: humanize(error))) }

        // 5. npm install (non-fatal — site still opens with the deps-not-installed preview state)
        emit(.installing)
        if let node = NodeRuntime.bundledExecutableURL {
            let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
            do {
                let r = try await run(node, [npm.path] + NodeModulesCache.shared.npmInstallArguments(), siteDir)
                if r.exitCode != 0 {
                    emit(.warning(step: "installing",
                                  message: "Dependencies didn't install — you can retry from the site window.\n\(r.stderr)"))
                }
            } catch { emit(.warning(step: "installing", message: humanize(error))) }
        } else {
            emit(.warning(step: "installing", message: "Bundled Node not found; skipped install."))
        }

        // 6. Register
        emit(.registering)
        do {
            let site = try await register(siteDir)
            emit(.done(siteID: site.id))
        } catch { emit(.failed(step: "registering", message: humanize(error))) }
    }

    /// Append SITE_NAME / SITE_TYPE / TAGLINE without clobbering existing lines (e.g. ANGLESITE_VERSION).
    private func appendSiteConfig(_ draft: NewSiteDraft, siteDir: URL) {
        let url = siteDir.appendingPathComponent(".site-config")
        var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        func setKey(_ key: String, _ value: String) {
            guard !contents.contains("\n\(key)=") && !contents.hasPrefix("\(key)=") else { return }
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
            contents += "\(key)=\(value)\n"
        }
        setKey("SITE_NAME", draft.name)
        setKey("SITE_TYPE", draft.siteType.rawValue)
        if !draft.tagline.isEmpty { setKey("TAGLINE", draft.tagline) }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func humanize(_ error: Error) -> String { (error as NSError).localizedDescription }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SiteScaffolderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteScaffolder.swift Tests/AnglesiteCoreTests/SiteScaffolderTests.swift
git commit -m "feat(onboarding): SiteScaffolder runs the deterministic new-site pipeline"
```

---

## Task 6: NewSiteWizardModel + wizard views

**Files:**
- Create: `Sources/AnglesiteCore/NewSiteWizardModel.swift`
- Create: `Sources/AnglesiteApp/NewSiteWizard.swift`
- Test: `Tests/AnglesiteCoreTests/NewSiteWizardModelTests.swift`

The model holds the testable logic (step validation, slug preview, default-theme-on-type-pick, running the scaffolder). The views are thin and not unit-tested.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnglesiteCore

@MainActor
final class NewSiteWizardModelTests: XCTestCase {
    private func catalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
        ])
    }

    func testPickingTypeSetsDefaultTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.choose(type: .blog)               // default for .blog is "warm"
        XCTAssertEqual(m.draft.themeID, "warm")
    }

    func testCannotContinuePastDetailsWithEmptyOrTakenName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { $0 == "taken" })
        m.step = .details
        m.draft.name = ""
        XCTAssertFalse(m.canContinue)
        m.draft.name = "Taken"              // slug "taken"
        XCTAssertFalse(m.canContinue)
        XCTAssertNotNil(m.detailsError)
        m.draft.name = "Fresh One"
        XCTAssertTrue(m.canContinue)
    }

    func testSlugPreviewTracksName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.draft.name = "My Cool Site"
        XCTAssertEqual(m.slugPreview, "my-cool-site")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NewSiteWizardModelTests`
Expected: FAIL — `cannot find 'NewSiteWizardModel'`.

- [ ] **Step 3: Write minimal implementation**

`NewSiteWizardModel.swift` (in `AnglesiteCore` — types are local, no `import AnglesiteCore`):
```swift
import Foundation
import Observation

@MainActor
@Observable
public final class NewSiteWizardModel {
    public enum Step: Int, CaseIterable { case type, details, look, content, building }

    public var step: Step = .type
    public var draft = NewSiteDraft(siteType: .business, name: "")
    public private(set) var progress: [SiteScaffolder.ScaffoldStep] = []
    public private(set) var fatal: SiteScaffolder.ScaffoldStep?   // .failed, if any
    public private(set) var completedSiteID: String?

    public let catalog: ThemeCatalog
    private let slugTaken: @Sendable (String) -> Bool

    public init(catalog: ThemeCatalog, slugTaken: @escaping @Sendable (String) -> Bool) {
        self.catalog = catalog
        self.slugTaken = slugTaken
        // Seed a default theme for the initial type.
        draft.themeID = catalog.defaultThemeID(for: draft.siteType)
    }

    public var slugPreview: String { SiteSlug.derive(from: draft.name) }

    public var detailsError: String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }              // empty is "incomplete", not an error to show
        if slugTaken(slugPreview) { return "A site named “\(slugPreview)” already exists." }
        return nil
    }

    public var canContinue: Bool {
        switch step {
        case .type:    return true
        case .details: return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && detailsError == nil
        case .look:    return catalog.theme(id: draft.themeID) != nil
        case .content: return true                  // content is optional
        case .building: return false
        }
    }

    public func choose(type: SiteType) {
        draft.siteType = type
        draft.themeID = catalog.defaultThemeID(for: type)
    }

    public func advance() { if let next = Step(rawValue: step.rawValue + 1) { step = next } }
    public func back() { if let prev = Step(rawValue: step.rawValue - 1) { step = prev } }

    /// Runs the scaffolder, accumulating progress. Returns the new site id on success.
    public func build(using scaffolder: SiteScaffolder) async -> String? {
        step = .building
        if draft.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.headline = draft.name
        }
        for await s in scaffolder.scaffold(draft) {
            progress.append(s)
            if case .failed = s { fatal = s }
            if case .done(let id) = s { completedSiteID = id }
        }
        return completedSiteID
    }
}
```

`NewSiteWizard.swift` (thin views; not unit-tested but must compile):
```swift
import SwiftUI
import AnglesiteCore

/// The New Site wizard sheet. Presented from SitesLauncherView; calls `onComplete(siteID)`
/// when the site is scaffolded and registered.
struct NewSiteWizard: View {
    @State var model: NewSiteWizardModel
    let scaffolder: SiteScaffolder
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .type:     typeStep
        case .details:  detailsStep
        case .look:     lookStep
        case .content:  contentStep
        case .building: buildingStep
        }
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What kind of site?").font(.title2.bold())
            ForEach(SiteType.allCases, id: \.self) { type in
                Button { model.choose(type: type) } label: {
                    HStack {
                        Image(systemName: type.symbol).frame(width: 24)
                        Text(type.label)
                        Spacer()
                        if model.draft.siteType == type { Image(systemName: "checkmark") }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 4)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name your site").font(.title2.bold())
            TextField("Site name", text: $model.draft.name)
            Text("Folder: ~/Sites/\(model.slugPreview)").font(.caption).foregroundStyle(.secondary)
            if let err = model.detailsError { Text(err).font(.caption).foregroundStyle(.red) }
            Text("Tagline (optional)").font(.headline).padding(.top, 8)
            TextField("A short line about your site", text: $model.draft.tagline)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a look").font(.title2.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                    ForEach(model.catalog.themes) { theme in
                        Button { model.draft.themeID = theme.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 0) {
                                    ForEach(theme.swatch, id: \.self) { hex in
                                        Color(hex: hex).frame(height: 28)
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(theme.name).font(.subheadline.bold())
                                Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(model.draft.themeID == theme.id ? Color.accentColor : Color.clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(24)
    }

    private var contentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First words").font(.title2.bold())
            Text("Homepage headline").font(.headline)
            TextField("Welcome to …", text: $model.draft.headline)
            Text("One line about you (optional)").font(.headline).padding(.top, 8)
            TextField("What you do, in a sentence", text: $model.draft.blurb)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your site…").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
            }
            if let f = model.fatal, case .failed(_, let msg) = f {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "✅ Created the site folder"
        case .copyingTemplate: return "✅ Copied the template"
        case .applyingTheme: return "✅ Applied your theme"
        case .writingContent: return "✅ Wrote your words"
        case .installing: return "⏳ Installing…"
        case .registering: return "✅ Registering"
        case .warning(_, let m): return "⚠️ \(m)"
        case .failed(_, let m): return "❌ \(m)"
        case .done: return "✅ Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .type && model.step != .building {
                Button("Back") { model.back() }
            }
            Spacer()
            Button("Cancel") { onCancel() }
            if model.step == .content {
                Button("Create Site") {
                    Task { if let id = await model.build(using: scaffolder) { onComplete(id) } }
                }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if model.step != .building {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Minimal hex -> Color for theme swatches (#rrggbb).
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self = Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NewSiteWizardModelTests`
Expected: PASS (3 tests). Then `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` to confirm the views compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/NewSiteWizardModel.swift Sources/AnglesiteApp/NewSiteWizard.swift Tests/AnglesiteAppTests/NewSiteWizardModelTests.swift
git commit -m "feat(onboarding): NewSiteWizard model + views"
```

---

## Task 7: Wire the wizard into SitesLauncherView

**Files:**
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift` (the `footer` "New Site…" label at lines ~134–144, and add state + sheet)

- [ ] **Step 1: Replace the disabled label with a live button + state**

In `SitesLauncherView`, add state near the existing `@State` declarations:
```swift
@State private var showingNewSite = false
@State private var wizardModel: NewSiteWizardModel?
@State private var scaffolder: SiteScaffolder?
```

Replace the `footer` body's `Text("New Site…") …` block with:
```swift
Button("New Site…") { Task { await presentNewSite() } }
```

Add the sheet to `launcherUI` (attach to the outer `VStack`):
```swift
.sheet(isPresented: $showingNewSite) {
    if let wizardModel, let scaffolder {
        NewSiteWizard(
            model: wizardModel,
            scaffolder: scaffolder,
            onComplete: { siteID in
                showingNewSite = false
                Task { await refreshSites(); openWindow(value: siteID); dismissWindow() }
            },
            onCancel: { showingNewSite = false }
        )
    }
}
```

- [ ] **Step 2: Add the presentation builder**

Add this method to `SitesLauncherView` (mirrors how `openFolder()` resolves sites root + MAS bookmark). The sites root is `AppSettings.shared.sitesRootOverride ?? ~/Sites`; confirm the exact accessor with `grep -n "sitesRoot\|Sites" Sources/AnglesiteCore/SiteStore.swift Sources/AnglesiteApp/*.swift` and use the existing one.

```swift
@MainActor
private func presentNewSite() async {
    let resolution = PluginRuntime.resolve()
    guard let pluginURL = resolution.url else {
        loadError = "Plugin not found — can't create a site. Reinstall the app."
        return
    }
    let catalog: ThemeCatalog
    do { catalog = try ThemeCatalog.load(pluginURL: pluginURL) }
    catch { loadError = "Couldn't load themes: \(error.localizedDescription)"; return }

    // Effective sites root (override or ~/Sites) — the same accessor SiteStore uses.
    let sitesRoot = AppSettings.shared.sitesRoot

    // MAS: creating ~/Sites/<slug> needs a security-scoped grant to the parent. If we don't
    // already hold one, prompt once via NSOpenPanel (defaulting to ~/Sites) to obtain it, and
    // keep the scope open for the lifetime of the scaffold. DevID (sandbox off) just creates it.
    #if ANGLESITE_MAS
    guard let rootScope = await ensureSitesRootAccess(sitesRoot) else { return }  // user cancelled
    defer { rootScope.stopAccessingSecurityScopedResource() }
    #endif
    try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

    let known = (try? await SiteStore.shared.refresh()) ?? []
    let takenSlugs = Set(known.map { SiteSlug.derive(from: $0.name) })

    let model = NewSiteWizardModel(catalog: catalog, slugTaken: { takenSlugs.contains($0) })

    scaffolder = SiteScaffolder(
        sitesRoot: sitesRoot,
        pluginURL: pluginURL,
        catalog: catalog,
        run: { exe, args, cwd in
            try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
        },
        register: { url in
            let site = try await SiteStore.shared.add(url)
            #if ANGLESITE_MAS
            let bookmark = try SecurityScopedBookmark.create(for: url)
            try await SiteStore.shared.setBookmark(bookmark, for: site.id)
            #endif
            return site
        }
    )
    wizardModel = model
    showingNewSite = true
}

#if ANGLESITE_MAS
/// Obtain (or reuse) a security-scoped grant to the sites root so the sandboxed build can
/// create a new site folder under it. Returns the started-accessing URL, or nil if the user
/// cancelled. Reuses `SecurityScopedBookmark` — persist an app-level bookmark in AppSettings so
/// the prompt happens at most once.
@MainActor
private func ensureSitesRootAccess(_ sitesRoot: URL) async -> URL? {
    // If we already persisted a sites-root bookmark, resolve + start it.
    if let data = AppSettings.shared.sitesRootBookmark,
       let resolved = try? SecurityScopedBookmark.resolve(data),
       resolved.url.startAccessingSecurityScopedResource() {
        return resolved.url
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = sitesRoot
    panel.prompt = "Grant Access"
    panel.message = "Choose your Sites folder so Anglesite can create the new site there."
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    if let data = try? SecurityScopedBookmark.create(for: url) {
        AppSettings.shared.sitesRootBookmark = data   // add this property to AppSettings
    }
    return url.startAccessingSecurityScopedResource() ? url : nil
}
#endif
```

> **AppSettings additions:** this references `AppSettings.shared.sitesRootURL` (existing sites-root accessor — use the real name) and a new `sitesRootBookmark: Data?` (MAS only). Add the `Data?` property following the existing `@AppStorage`/UserDefaults pattern in `AppSettings`; it stores the security-scoped bookmark for the sites root so the grant survives relaunch.

- [ ] **Step 3: Build to verify it compiles (both targets)**

Run:
```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build
```
Expected: BUILD SUCCEEDED for both. (The MAS branch compiles the `SecurityScopedBookmark` path; DevID omits it.)

- [ ] **Step 4: Manual smoke (documented, run by maintainer)**

With `../anglesite` checked out and the app run from Xcode:
1. Open the Sites launcher → click **New Site…**.
2. Pick *Business* → name "Smoke Test" → confirm folder reads `~/Sites/smoke-test` → pick a theme → enter a headline → **Create Site**.
3. Watch the build steps; confirm the window opens and the preview renders the headline (or shows the deps-not-installed state if `npm install` was offline).
4. Confirm `~/Sites/smoke-test/.site-config` contains `ANGLESITE_VERSION`, `SITE_NAME`, `SITE_TYPE`, and `src/styles/global.css` shows the theme's `--color-primary`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SitesLauncherView.swift Sources/AnglesiteCore/AppSettings.swift
git commit -m "feat(onboarding): wire New Site wizard into the launcher"
```

---

## Final verification

- [ ] Run the reliable gate: `swift test --filter AnglesiteCoreTests` — all green (drift-guard test passes with `../anglesite` present, skips otherwise).
- [ ] Run `swift test --filter NewSiteWizardModelTests` — green.
- [ ] Both schemes build: `xcodebuild … -scheme Anglesite` and `… -scheme AnglesiteMAS`.
- [ ] Update `docs/build-plan.md` Phase 9.1 note: replace "New Site… button in the launcher (placeholder today …)" with a line pointing at this feature; mention the freedesignmd-in-wizard follow-up remains open.
