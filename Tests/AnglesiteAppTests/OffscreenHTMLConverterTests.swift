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
}
