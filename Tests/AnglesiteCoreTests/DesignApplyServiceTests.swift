// Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DesignApplyServiceTests {
    private func makeSite() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root {
          --color-primary: #2563eb;
          --color-accent: #f59e0b;
          --font-heading: system-ui, -apple-system, sans-serif;
        }

        * { box-sizing: border-box; }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func updatesExistingVarsInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
        #expect(css.contains("--color-accent: #f59e0b;")) // untouched var preserved
    }

    @Test func addsNewVarsNotPreviouslyInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-surface": "#eeeeee"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-surface: #eeeeee;"))
    }

    @Test func preservesEverythingOutsideRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("* { box-sizing: border-box; }"))
    }

    @Test func writesRationaleWhenProvided() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: "# Design", brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("docs/DESIGN.md"))
        let md = try String(contentsOf: dir.appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
        #expect(md == "# Design")
    }

    @Test func skipsRationaleFileWhenNil() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Test")
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else { Issue.record("expected success"); return }
        #expect(!applied.writtenFiles.contains("docs/DESIGN.md"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/DESIGN.md").path))
    }

    @Test func appendsBrandSummaryToNewBrandMd() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Built-in theme: Warm")
        _ = DesignApplyService.apply(input, to: dir)
        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("Built-in theme: Warm"))
        #expect(brand.contains("A test brand."))
    }

    @Test func failsWhenGlobalCSSMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = DesignApplyInput(cssVars: ["color-primary": "#fff"], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .failure(.missingGlobalCSS) = result else { Issue.record("expected .missingGlobalCSS"); return }
    }

    @Test func failsWithMissingRootBlockWhenGlobalCSSHasNoRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = "* { box-sizing: border-box; }\n"
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: ["color-primary": "#fff"], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .failure(.missingRootBlock) = result else { Issue.record("expected .missingRootBlock"); return }
    }

    @Test func appendsBrandSummaryAcrossMultipleApplies() throws {
        let dir = try makeSite()
        let firstInput = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "First brand summary.", sourceLabel: "Built-in theme: Warm")
        _ = DesignApplyService.apply(firstInput, to: dir)
        let secondInput = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "Second brand summary.", sourceLabel: "Built-in theme: Cool")
        _ = DesignApplyService.apply(secondInput, to: dir)

        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("Built-in theme: Warm"))
        #expect(brand.contains("First brand summary."))
        #expect(brand.contains("Built-in theme: Cool"))
        #expect(brand.contains("Second brand summary."))
    }

    /// A `FileManager` subclass that fails `createDirectory` once a target path matches a
    /// given substring, used to force a partial-write failure partway through `apply`.
    private final class FailingFileManager: FileManager, @unchecked Sendable {
        let failingPathSubstring: String

        init(failingPathSubstring: String) {
            self.failingPathSubstring = failingPathSubstring
            super.init()
        }

        override func createDirectory(
            at url: URL,
            withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            if url.path.contains(failingPathSubstring) {
                throw NSError(domain: "DesignApplyServiceTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "forced failure creating \(url.path)",
                ])
            }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
    }

    @Test func emptyCSSVarsSkipsGlobalCSSAndSucceedsWithNoCSSFileAtAll() throws {
        // No src/styles directory at all — not even a malformed global.css.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let input = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: "# Design", brandSummary: "freedesignmd description.",
            sourceLabel: "freedesignmd: acme"
        )
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }

        #expect(!applied.writtenFiles.contains("src/styles/global.css"))
        #expect(applied.writtenFiles.contains("docs/DESIGN.md"))
        #expect(applied.writtenFiles.contains("docs/brand.md"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/styles/global.css").path))

        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("freedesignmd: acme"))
        #expect(brand.contains("freedesignmd description."))
        let rationale = try String(contentsOf: dir.appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
        #expect(rationale == "# Design")
    }

    @Test func emptyCSSVarsSkipsGlobalCSSAndSucceedsWithMalformedGlobalCSS() throws {
        // A global.css that exists but has no `:root` block — would normally trip
        // .missingRootBlock, but must not for an empty-cssVars caller.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let originalCSS = "* { box-sizing: border-box; }\n"
        try originalCSS.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "freedesignmd: acme")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }
        #expect(!applied.writtenFiles.contains("src/styles/global.css"))

        // global.css itself is untouched.
        let css = try String(contentsOf: stylesDir.appendingPathComponent("global.css"), encoding: .utf8)
        #expect(css == originalCSS)
    }

    @Test func ignoresAttributeSelectorRootAndUpdatesTheBareRootBlock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root[data-theme="dark"] {
          --color-primary: #000000;
        }

        :root {
          --color-primary: #2563eb;
        }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let updated = try String(contentsOf: stylesDir.appendingPathComponent("global.css"), encoding: .utf8)
        // The attribute-selector block must be left untouched — only the bare `:root` block updates.
        #expect(updated.contains("[data-theme=\"dark\"] {\n  --color-primary: #000000;"))
        #expect(updated.contains(":root {\n  --color-primary: #ff0000;"))
    }

    @Test func skipsRootBlockNestedInsideAMediaQueryAndUpdatesTheTopLevelOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        @media (prefers-color-scheme: dark) {
          :root {
            --color-primary: #000000;
          }
        }

        :root {
          --color-primary: #2563eb;
        }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let updated = try String(contentsOf: stylesDir.appendingPathComponent("global.css"), encoding: .utf8)
        // The @media-nested :root must be left untouched — only the top-level block updates.
        #expect(updated.contains("@media (prefers-color-scheme: dark) {\n  :root {\n    --color-primary: #000000;"))
        #expect(updated.contains("\n:root {\n  --color-primary: #ff0000;"))
    }

    @Test func updatesEveryDuplicateDeclarationOfTheSameProperty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        // A hand-edited :root block declaring --color-primary twice — CSS gives the LAST
        // declaration precedence, so both must be rewritten or the stale first one would look
        // "updated" in isolation while the real, cascading value stayed old.
        let css = """
        :root {
          --color-primary: #111111;
          --color-accent: #f59e0b;
          --color-primary: #222222;
        }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let updated = try String(contentsOf: stylesDir.appendingPathComponent("global.css"), encoding: .utf8)
        #expect(updated.components(separatedBy: "--color-primary: #111111;").count == 1) // gone
        #expect(updated.components(separatedBy: "--color-primary: #222222;").count == 1) // gone
        #expect(updated.components(separatedBy: "--color-primary: #ff0000;").count == 3) // both replaced
        #expect(updated.contains("--color-accent: #f59e0b;")) // untouched var preserved
    }

    @Test func writesDesignAndProductContextDocumentsWhenProvided() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x",
            designContextMarkdown: "generated design context", productContextMarkdown: "generated product context"
        )
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.writtenFiles.contains("PRODUCT.md"))
        #expect(applied.skippedNotices.isEmpty)
        #expect(try String(contentsOf: dir.appendingPathComponent("DESIGN.md"), encoding: .utf8) == "generated design context")
        #expect(try String(contentsOf: dir.appendingPathComponent("PRODUCT.md"), encoding: .utf8) == "generated product context")
    }

    @Test func skipsDesignAndProductContextDocumentsWhenNilAndWritesNoFiles() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else {
            Issue.record("expected success"); return
        }
        #expect(!applied.writtenFiles.contains("DESIGN.md"))
        #expect(!applied.writtenFiles.contains("PRODUCT.md"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("DESIGN.md").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("PRODUCT.md").path))
    }

    @Test func regeneratesDesignContextDocumentWhenStillOwnedByThisGenerator() throws {
        let dir = try makeSite()
        let firstInput = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x",
            designContextMarkdown: GeneratedDesignDocument.marker + "\n\nfirst version"
        )
        _ = DesignApplyService.apply(firstInput, to: dir)

        let secondInput = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x",
            designContextMarkdown: GeneratedDesignDocument.marker + "\n\nsecond version"
        )
        guard case .success(let applied) = DesignApplyService.apply(secondInput, to: dir) else {
            Issue.record("expected success"); return
        }
        #expect(applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.skippedNotices.isEmpty)
        let contents = try String(contentsOf: dir.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        #expect(contents.contains("second version"))
        #expect(!contents.contains("first version"))
    }

    @Test func leavesHandEditedDesignContextDocumentUntouchedWithNotice() throws {
        let dir = try makeSite()
        try "# My own design notes — please don't overwrite".write(
            to: dir.appendingPathComponent("DESIGN.md"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x",
            designContextMarkdown: GeneratedDesignDocument.marker + "\n\ngenerated content"
        )
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else {
            Issue.record("expected success"); return
        }
        #expect(!applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.skippedNotices.contains { $0.contains("DESIGN.md") })
        let contents = try String(contentsOf: dir.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        #expect(contents == "# My own design notes — please don't overwrite")
    }

    @Test func leavesHandEditedProductContextDocumentUntouchedWithNotice() throws {
        let dir = try makeSite()
        try "# My own product notes".write(
            to: dir.appendingPathComponent("PRODUCT.md"), atomically: true, encoding: .utf8)

        let input = DesignApplyInput(
            cssVars: [:], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x",
            productContextMarkdown: GeneratedDesignDocument.marker + "\n\ngenerated content"
        )
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else {
            Issue.record("expected success"); return
        }
        #expect(!applied.writtenFiles.contains("PRODUCT.md"))
        #expect(applied.skippedNotices.contains { $0.contains("PRODUCT.md") })
        let contents = try String(contentsOf: dir.appendingPathComponent("PRODUCT.md"), encoding: .utf8)
        #expect(contents == "# My own product notes")
    }

    @Test func writeFailureAfterGlobalCSSReportsPartiallyWrittenFiles() throws {
        let dir = try makeSite()
        let failingManager = FailingFileManager(failingPathSubstring: "docs")
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir, fileManager: failingManager)

        guard case .failure(.writeFailed(_, let partiallyWritten)) = result else {
            Issue.record("expected .writeFailed"); return
        }
        #expect(partiallyWritten == ["src/styles/global.css"])

        // The CSS write itself succeeded on disk even though the overall apply failed.
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
    }
}

extension DesignApplyServiceTests {
    /// Builds a real `.anglesite` package layout: a package root containing a `Source/`
    /// subdirectory with the `src/styles/global.css` fixture nested underneath, matching
    /// `AnglesitePackage.sourceURL`'s real `url/Source` invariant (not a synthetic wrapper).
    private func makePackageRoot() throws -> URL {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root {
          --color-primary: #2563eb;
          --color-accent: #f59e0b;
          --font-heading: system-ui, -apple-system, sans-serif;
        }

        * { box-sizing: border-box; }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return packageRoot
    }

    @Test func packageOverloadDelegatesToSourceDirectory() throws {
        let packageRoot = try makePackageRoot()
        let package = AnglesitePackage(url: packageRoot)
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: package)
        guard case .success = result else { Issue.record("expected success"); return }
        let css = try String(contentsOf: packageRoot.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
    }
}
