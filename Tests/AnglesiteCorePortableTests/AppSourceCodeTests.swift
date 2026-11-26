// Lives in the portable target on purpose: AppSourceCode is pure Foundation, and this is the only
// test target the Linux CI leg executes (AnglesiteCoreTests isn't purity-swept; see Package.swift).
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("AppSourceCode")
struct AppSourceCodeTests {
    private let sha1 = "daf9338dc5ae6a0623c9d24203d53b511e82771e"

    @Test("a stamped release links to its exact source")
    func stampedRevision() {
        let source = AppSourceCode(infoDictionary: [AppSourceCode.infoPlistKey: sha1])
        #expect(source.revision == sha1)
        #expect(source.isExactBuild)
        #expect(source.url.absoluteString == "https://github.com/Anglesite/Anglesite/tree/\(sha1)")
    }

    @Test("an unstamped build links to the repository", arguments: [nil, "", "   "] as [String?])
    func unstampedBuild(value: String?) {
        let source = AppSourceCode(infoDictionary: value.map { [AppSourceCode.infoPlistKey: $0] } ?? [:])
        #expect(source.revision == nil)
        #expect(!source.isExactBuild)
        #expect(source.url == AppSourceCode.repositoryURL)
    }

    @Test("a missing Info.plist links to the repository")
    func missingInfoDictionary() {
        #expect(AppSourceCode(infoDictionary: nil).url == AppSourceCode.repositoryURL)
    }

    @Test("an unexpanded or malformed value is ignored", arguments: [
        "$(ANGLESITE_SOURCE_REVISION)", // the build setting was never defined
        "daf9338",                      // abbreviated
        "zaf9338dc5ae6a0623c9d24203d53b511e82771e", // not hex
        "../../etc",
    ])
    func malformed(value: String) {
        let source = AppSourceCode(revision: value)
        #expect(source.revision == nil)
        #expect(source.url == AppSourceCode.repositoryURL)
    }

    @Test("revisions are normalized: whitespace trimmed, lowercased, SHA-256 accepted")
    func normalization() {
        #expect(AppSourceCode(revision: " \(sha1.uppercased())\n").revision == sha1)
        let sha256 = String(repeating: "ab", count: 32)
        #expect(AppSourceCode(revision: sha256).revision == sha256)
    }

    @Test("a non-string Info.plist value is ignored")
    func nonStringValue() {
        #expect(AppSourceCode(infoDictionary: [AppSourceCode.infoPlistKey: 42]).revision == nil)
    }
}
