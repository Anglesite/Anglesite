import Foundation
import Testing
@testable import AnglesiteCore

struct ThemeCatalogTests {

    // A trimmed fixture mirroring the real themes.json shape (two themes, varied fonts).
    private let fixture = Data("""
    [
      {
        "id": "classic",
        "displayName": "Classic",
        "description": "Traditional, trustworthy, professional",
        "bestFor": ["legal", "finance"],
        "vars": {
          "color-primary": "#1e3a5f",
          "color-accent": "#c8a951",
          "font-heading": "Georgia, 'Times New Roman', serif",
          "font-body": "system-ui, -apple-system, sans-serif"
        }
      },
      {
        "id": "studio",
        "displayName": "Studio",
        "description": "Dark mode for creative coders",
        "bestFor": ["generative-art"],
        "vars": {
          "color-primary": "#00ff88",
          "color-accent": "#00ff88",
          "font-heading": "monospace",
          "font-body": "monospace"
        }
      }
    ]
    """.utf8)

    @Test func parsesThemesInOrder() throws {
        let themes = try ThemeCatalog.parse(themesJSON: fixture)
        #expect(themes.map(\.id) == ["classic", "studio"])
        #expect(themes[0].name == "Classic")
        #expect(themes[0].blurb == "Traditional, trustworthy, professional")
        #expect(themes[0].cssVars["color-primary"] == "#1e3a5f")
        // Font value with embedded commas + single quotes survives intact.
        #expect(themes[0].cssVars["font-heading"] == "Georgia, 'Times New Roman', serif")
        #expect(themes[0].swatch == ["#1e3a5f", "#c8a951"])
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try ThemeCatalog.parse(themesJSON: Data("not json".utf8))
        }
    }

    @Test func defaultThemeIDResolvesForEverySiteType() throws {
        let catalog = ThemeCatalog(themes: try ThemeCatalog.parse(themesJSON: fixture))
        for type in SiteType.allCases {
            let id = catalog.defaultThemeID(for: type)
            #expect(catalog.theme(id: id) != nil, "no theme for \(type)")
        }
    }

    @Test func defaultThemeIDUsesPreferredMappingWhenPresent() {
        let ids = ["classic", "elegant", "warm", "bold", "community", "astrowind", "cactus", "astropaper", "astroplate"]
        let catalog = ThemeCatalog(themes: ids.map {
            Theme(id: $0, name: $0, blurb: "", swatch: [], cssVars: [:])
        })
        #expect(catalog.defaultThemeID(for: .business) == "astrowind")
        #expect(catalog.defaultThemeID(for: .personal) == "cactus")
        #expect(catalog.defaultThemeID(for: .blog) == "astropaper")
        #expect(catalog.defaultThemeID(for: .portfolio) == "bold")
        #expect(catalog.defaultThemeID(for: .organization) == "astroplate")
        #expect(catalog.defaultThemeID(for: .community) == "community")
    }

    @Test func testParseDecodesPackFields() throws {
        let json = """
        [{"id": "paper", "displayName": "Paper", "description": "A ported blog theme",
          "bestFor": ["blog"], "category": "blog", "pack": "paper",
          "thumbnail": "packs/paper/thumbnail.png",
          "credit": {"name": "AstroPaper", "url": "https://example.com/astropaper", "license": "MIT"},
          "vars": {"color-primary": "#111111", "color-accent": "#ff5500"}},
         {"id": "classic", "displayName": "Classic", "description": "Built-in",
          "bestFor": ["legal"], "vars": {"color-primary": "#1e3a5f"}}]
        """
        let themes = try ThemeCatalog.parse(themesJSON: Data(json.utf8))
        #expect(themes[0].category == "blog")
        #expect(themes[0].pack == "paper")
        #expect(themes[0].thumbnail == "packs/paper/thumbnail.png")
        #expect(themes[0].credit == Theme.Credit(name: "AstroPaper", url: "https://example.com/astropaper", license: "MIT"))
        // Entries without the new fields (all 8 built-ins) decode with nils.
        #expect(themes[1].category == nil)
        #expect(themes[1].pack == nil)
        #expect(themes[1].thumbnail == nil)
        #expect(themes[1].credit == nil)
    }

    // DRIFT GUARD: decode the REAL bundled themes.json from the in-repo template.
    @Test func realThemesFileParsesToEightCompleteThemes() throws {
        let themes = try ThemeCatalog.parse(themesJSON: Data(contentsOf: Self.realThemesURL()))
        #expect(themes.count == 12, "expected 8 built-in themes + 4 ported packs (astrowind, cactus, astropaper, astroplate)")
        // A duplicate id would silently collide in theme(id:)'s first{} lookup (and in the
        // template's Object.fromEntries) — enforce uniqueness at the source.
        let ids = themes.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate theme id in themes.json: \(ids)")
        for theme in themes {
            for key in ["color-primary", "color-accent", "font-heading", "font-body"] {
                #expect(theme.cssVars[key] != nil, "\(theme.id) missing --\(key)")
            }
        }
        let catalog = ThemeCatalog(themes: themes)
        for type in SiteType.allCases {
            #expect(catalog.theme(id: catalog.defaultThemeID(for: type)) != nil)
        }
    }

    // DRIFT GUARD: every category that has a ported pack must have its flagship wired up —
    // `defaultThemeID(for:)` resolves to a real catalog entry that actually carries `pack`,
    // `category`, `thumbnail`, and `credit`, so the chooser's per-category pre-selection can
    // never land on a plain CSS-var theme once a pack ships for that category (spec §4).
    @Test func portedCategoriesPreselectTheirFlagshipPack() throws {
        let catalog = ThemeCatalog(themes: try ThemeCatalog.parse(themesJSON: Data(contentsOf: Self.realThemesURL())))
        for (type, category) in [
            (SiteType.business, "business"), (SiteType.personal, "personal"), (SiteType.blog, "blog"),
            (SiteType.organization, "organization"),
        ] {
            let theme = try #require(catalog.theme(id: catalog.defaultThemeID(for: type)))
            #expect(theme.category == category, "\(type) preselects \(theme.id), category \(theme.category ?? "nil")")
            #expect(theme.pack != nil, "\(theme.id) is not a pack entry")
            #expect(theme.thumbnail != nil, "\(theme.id) has no thumbnail")
            #expect(theme.credit != nil, "\(theme.id) has no credit")
        }
    }

    // DRIFT GUARD: a pack entry's `vars` must match the palette its global.css already bakes
    // in, so ThemeApplier's post-scaffold rewrite is a no-op reaffirmation (spec §3) rather
    // than a silent recolor of the port. Applies each real pack theme to its own real CSS.
    @Test func packThemeVarsMatchTheirBakedInPalette() throws {
        let template = Self.realThemesURL().deletingLastPathComponent().deletingLastPathComponent()
        let themes = try ThemeCatalog.parse(themesJSON: Data(contentsOf: Self.realThemesURL()))
        let packs = themes.filter { $0.pack != nil }
        #expect(!packs.isEmpty, "no pack entries in themes.json — this guard would vacuously pass")
        for theme in packs {
            let css = template.appendingPathComponent("packs/\(theme.pack!)/src/styles/global.css")
            let before = try String(contentsOf: css, encoding: .utf8)
            #expect(ThemeApplier.apply(theme, toCSS: before) == before,
                    "\(theme.id): applying the catalog vars rewrites packs/\(theme.pack!)'s global.css")
        }
    }

    /// Resolve the real themes.json from the in-repo template (Resources/Template/).
    static func realThemesURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template/scripts/themes.json")
    }
}
