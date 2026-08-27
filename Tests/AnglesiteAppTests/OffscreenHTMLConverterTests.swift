import Foundation
import Testing
@testable import AnglesiteAppCore

@Suite("OffscreenHTMLConverter")
@MainActor
struct OffscreenHTMLConverterTests {
    @Test func wrapsAFragmentInAMinimalDocumentShell() {
        let wrapped = OffscreenHTMLConverter.wrap("<p>Hi</p>")
        #expect(wrapped == "<!doctype html><html><body><p>Hi</p></body></html>")
    }

    @Test func wrapsAnEmptyFragmentWithoutCrashing() {
        #expect(OffscreenHTMLConverter.wrap("") == "<!doctype html><html><body></body></html>")
    }

    @Test func extractScriptCallsTheInjectedGlobalWithAFallback() {
        // `?? ""` matters: before the injected script has run (e.g. a load that errored), the
        // global is undefined, and evaluateJavaScript must still resolve to a string, not throw.
        #expect(OffscreenHTMLConverter.extractScript.contains("__anglesiteImportExtract"))
        #expect(OffscreenHTMLConverter.extractScript.contains("??"))
    }

    @Test func decodesAWellFormedExtractionRecord() {
        let json = """
        {"title":"Hi","byline":null,"publishedISO":null,"lang":null,"canonical":null,
         "markdown":"Hi there.","excerpt":null,"images":["https://example.com/cat.jpg"],
         "mf2JSON":null,"feedLinks":[]}
        """
        let decoded = OffscreenHTMLConverter.decodeExtraction(json)
        #expect(decoded?.markdown == "Hi there.")
        #expect(decoded?.images == ["https://example.com/cat.jpg"])
    }

    @Test func malformedJSONDecodesToNil() {
        #expect(OffscreenHTMLConverter.decodeExtraction("not json") == nil)
    }

    /// This decouples the resource-PATH-construction logic from Xcode's actual bundling — it
    /// can't catch a future "forgot to add Resources/ImportEngine to project.yml's Anglesite
    /// target `sources:`" regression (nothing but a real Xcode build can, see the app-build
    /// verification in the #1636 final-review fix report), but it does catch a path-construction
    /// typo in `importEngineSource(bundle:)` itself.
    @Test func importEngineSourceReadsTheBundledJSFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offscreen-html-converter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let engineDir = tempDir.appendingPathComponent("ImportEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        try "window.__anglesiteImportExtract = () => \"{}\";".write(
            to: engineDir.appendingPathComponent("import-engine.js"), atomically: true, encoding: .utf8)

        // A plain directory `Bundle` resolves `resourceURL` to itself — enough to exercise
        // `importEngineSource`'s path-joining without needing a real .bundle/.app structure.
        let bundle = try #require(Bundle(url: tempDir))
        let source = OffscreenHTMLConverter.importEngineSource(bundle: bundle)
        #expect(source == "window.__anglesiteImportExtract = () => \"{}\";")
    }

    @Test func importEngineSourceReturnsNilWhenTheResourceIsMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offscreen-html-converter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundle = try #require(Bundle(url: tempDir))
        #expect(OffscreenHTMLConverter.importEngineSource(bundle: bundle) == nil)
    }
}
