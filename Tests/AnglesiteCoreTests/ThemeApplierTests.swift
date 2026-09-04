import Testing
import Foundation
@testable import AnglesiteCore

struct ThemeApplierTests {
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

    @Test("replaces only the provided properties")
    func replacesProvidedPropertiesOnly() {
        let out = ThemeApplier.apply(theme, toCSS: css)
        #expect(out.contains("--color-primary: #e65100;"))
        #expect(out.contains("--color-accent: #c62828;"))
        #expect(out.contains("--font-heading: Georgia, 'Times New Roman', serif;"))
        // Untouched, no matching cssVars key:
        #expect(out.contains("--space-md: 1rem;"))
        #expect(out.contains("--radius-sm: 4px;"))
    }

    @Test("is idempotent")
    func isIdempotent() {
        let once = ThemeApplier.apply(theme, toCSS: css)
        let twice = ThemeApplier.apply(theme, toCSS: once)
        #expect(once == twice)
    }

    @Test("writes the file in place")
    func writesFileInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cssPath = dir.appendingPathComponent("src/styles/global.css")
        try FileManager.default.createDirectory(at: cssPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try css.write(to: cssPath, atomically: true, encoding: .utf8)
        try ThemeApplier.apply(theme, siteDirectory: dir)
        let out = try String(contentsOf: cssPath, encoding: .utf8)
        #expect(out.contains("--color-primary: #e65100;"))
    }

    @Test("a value containing a dollar sign and a backslash")
    func valueContainingDollarAndBackslash() {
        let theme = Theme(id: "t", name: "", blurb: "", swatch: [],
                          cssVars: ["color-primary": #"url($1\path)"#])
        let css = ":root { --color-primary: #fff; }"
        let out = ThemeApplier.apply(theme, toCSS: css)
        #expect(out.contains(#"--color-primary: url($1\path);"#))
    }
}
