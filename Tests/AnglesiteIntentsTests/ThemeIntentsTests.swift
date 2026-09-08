import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("ApplyThemeIntent")
    struct ThemeIntentsTests {
        private static let sunset = Theme(
            id: "sunset", name: "Sunset", blurb: "warm hues",
            swatch: ["#ff0000", "#00ff00"], cssVars: ["color-primary": "#ff0000"])
        private static let catalog = ThemeCatalog(themes: [sunset])

        /// A throwaway `.anglesite` package with a `Source/src/styles/global.css` containing a
        /// `:root` block, so `DesignApplyService.apply` can actually write into it.
        private func makePackage() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apply-theme-tests-\(UUID().uuidString).anglesite", isDirectory: true)
            let stylesDir = root.appendingPathComponent("Source/src/styles", isDirectory: true)
            try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
            try "html { color: black; }\n:root {\n  --color-primary: #000000;\n}\n"
                .write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
            return root
        }

        private func entity(directory: URL?) -> SiteEntity {
            SiteEntity(id: "s1", name: "Portfolio", creationDate: nil, modificationDate: nil, directory: directory)
        }

        @Test("an unrecognized theme id lists the available themes instead of applying anything")
        func unknownThemeListsAvailableThemes() async throws {
            var intent = ApplyThemeIntent()
            intent.site = entity(directory: URL(fileURLWithPath: "/tmp/unused"))
            intent.themeID = "does-not-exist"

            let dialog = try await ThemeCatalogOverride.$scoped.withValue(Self.catalog) {
                try await intent.performForTesting()
            }

            #expect(dialog.contains("I don't recognize that theme"))
            #expect(dialog.contains("Sunset"))
        }

        @Test("a site with no resolvable location reports it can't be found")
        func missingDirectoryReportsNotFound() async throws {
            var intent = ApplyThemeIntent()
            intent.site = entity(directory: nil)
            intent.themeID = Self.sunset.id

            let dialog = try await ThemeCatalogOverride.$scoped.withValue(Self.catalog) {
                try await intent.performForTesting()
            }

            #expect(dialog.contains("couldn't find"))
        }

        @Test("applies the theme's CSS vars to the site's stylesheet and reports success")
        func appliesThemeVars() async throws {
            let package = try makePackage()
            defer { try? FileManager.default.removeItem(at: package) }
            let cssURL = package.appendingPathComponent("Source/src/styles/global.css")

            var intent = ApplyThemeIntent()
            intent.site = entity(directory: package)
            intent.themeID = Self.sunset.id

            let dialog = try await ThemeCatalogOverride.$scoped.withValue(Self.catalog) {
                try await intent.performForTesting()
            }

            #expect(dialog.contains("Applied the Sunset theme"))
            #expect(try String(contentsOf: cssURL, encoding: .utf8).contains("--color-primary: #ff0000;"))

            let designMD = try String(contentsOf: package.appendingPathComponent("Source/DESIGN.md"), encoding: .utf8)
            #expect(designMD.contains("`sunset`"))
            #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Source/PRODUCT.md").path))
        }

        @Test("a site missing its stylesheet reports the failure instead of throwing")
        func missingStylesheetReportsFailure() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apply-theme-tests-\(UUID().uuidString).anglesite", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Source"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            var intent = ApplyThemeIntent()
            intent.site = entity(directory: root)
            intent.themeID = Self.sunset.id

            let dialog = try await ThemeCatalogOverride.$scoped.withValue(Self.catalog) {
                try await intent.performForTesting()
            }

            #expect(dialog.contains("couldn't find this site's stylesheet"))
        }
    }
}
