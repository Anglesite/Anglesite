import Testing
@testable import AnglesiteCore

struct AnnotationFeedTests {
    @Test("decodes a single plugin annotation")
    func decodesSinglePluginAnnotation() throws {
        let json = #"""
        [{"id":"abc12345","path":"/about","selector":"h1","text":"tighter tone here","resolved":false,"createdAt":"2026-05-24T10:00:00Z"}]
        """#
        let parsed = try AnnotationFeedFactory.decode(jsonText: json)
        #expect(parsed.count == 1)
        #expect(parsed[0].id == "abc12345")
        #expect(parsed[0].path == "/about")
        #expect(parsed[0].text == "tighter tone here")
        #expect(!parsed[0].resolved)
        #expect(parsed[0].resolvedAt == nil)
        #expect(parsed[0].sourceFile == nil)
    }

    @Test("decodes an array with mixed resolved states")
    func decodesArrayWithMixedResolvedStates() throws {
        let json = #"""
        [
          {"id":"a","path":"/","selector":"#hero","text":"a","resolved":false,"createdAt":"2026-05-24T10:00:00Z"},
          {"id":"b","path":"/contact","selector":".form","text":"b","resolved":true,"createdAt":"2026-05-23T09:00:00Z","resolvedAt":"2026-05-23T11:00:00Z","sourceFile":"src/pages/contact.astro"}
        ]
        """#
        let parsed = try AnnotationFeedFactory.decode(jsonText: json)
        #expect(parsed.count == 2)
        #expect(parsed[1].sourceFile == "src/pages/contact.astro")
        #expect(parsed[1].resolved)
        #expect(parsed[1].resolvedAt != nil)
    }

    @Test("empty JSON array decodes to empty")
    func emptyJSONArrayDecodesToEmpty() throws {
        #expect(try AnnotationFeedFactory.decode(jsonText: "[]") == [])
    }

    @Test("malformed JSON throws")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try AnnotationFeedFactory.decode(jsonText: "{not json}")
        }
    }

    @Test("empty string decodes to empty")
    func emptyStringDecodesToEmpty() throws {
        #expect(try AnnotationFeedFactory.decode(jsonText: "") == [])
    }
}
