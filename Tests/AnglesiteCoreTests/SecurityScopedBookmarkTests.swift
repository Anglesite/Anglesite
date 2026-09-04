import Testing
import Foundation
@testable import AnglesiteCore

struct SecurityScopedBookmarkTests {
    /// On non-sandboxed test runs, bookmarks created with .withSecurityScope still produce
    /// resolvable Data; they just don't actually scope anything. That's enough to verify the
    /// create/resolve round-trip on the SPM test runner.
    @Test("create and resolve round trip")
    func createAndResolveRoundTrip() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/tmp"),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bookmark = try SecurityScopedBookmark.create(for: tmp)
        #expect(!bookmark.isEmpty)

        let resolved = try SecurityScopedBookmark.resolve(bookmark)
        #expect(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path ==
            tmp.standardizedFileURL.resolvingSymlinksInPath().path
        )
        #expect(!resolved.isStale)
    }

    @Test("resolving corrupt data throws")
    func resolveCorruptDataThrows() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04])
        #expect(throws: (any Error).self) {
            try SecurityScopedBookmark.resolve(garbage)
        }
    }

    /// #1068: without `LocalizedError` conformance, `.localizedDescription` on this enum bridges
    /// to a generic NSError ("The operation couldn't be completed. (AnglesiteCore.
    /// SecurityScopedBookmarkError error 0.)") and silently drops the actual underlying reason —
    /// exactly the message users saw in the bug report, on both the recovery ("Locate…") and
    /// brand-new-site paths.
    @Test("createFailed's localizedDescription surfaces the underlying message")
    func createFailedLocalizedDescriptionSurfacesUnderlyingMessage() {
        let error: Error = SecurityScopedBookmarkError.createFailed("the real underlying reason")
        #expect(error.localizedDescription == "the real underlying reason")
    }

    @Test("resolveFailed's localizedDescription surfaces the underlying message")
    func resolveFailedLocalizedDescriptionSurfacesUnderlyingMessage() {
        let error: Error = SecurityScopedBookmarkError.resolveFailed("the real underlying reason")
        #expect(error.localizedDescription == "the real underlying reason")
    }
}
