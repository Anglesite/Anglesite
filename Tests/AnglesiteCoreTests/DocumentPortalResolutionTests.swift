// Unit tests for DocumentPortalResolution's pure helpers. Gated the same as the type under test —
// document-portal FUSE resolution is a Flatpak/Linux-only concern (cross-platform port design §7,
// Flatpak packaging investigation §6).
#if canImport(Glibc)
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DocumentPortalResolution")
struct DocumentPortalResolutionTests {
    @Test("parses the in-sandbox /run/flatpak/doc alias with no remainder")
    func parsesFlatpakAliasTopLevel() {
        let parsed = DocumentPortalResolution.parseDocumentPortalPath(
            "/run/flatpak/doc/63a3dc48/MySite.anglesite")
        #expect(parsed?.docID == "63a3dc48")
        #expect(parsed?.remainder == [])
    }

    @Test("parses the in-sandbox /run/flatpak/doc alias with a nested remainder")
    func parsesFlatpakAliasWithRemainder() {
        let parsed = DocumentPortalResolution.parseDocumentPortalPath(
            "/run/flatpak/doc/63a3dc48/MySite.anglesite/Source")
        #expect(parsed?.docID == "63a3dc48")
        #expect(parsed?.remainder == ["Source"])
    }

    @Test("parses the host-visible /run/user/<uid>/doc mount")
    func parsesHostUserMount() {
        let parsed = DocumentPortalResolution.parseDocumentPortalPath(
            "/run/user/1000/doc/63a3dc48/MySite.anglesite/Source")
        #expect(parsed?.docID == "63a3dc48")
        #expect(parsed?.remainder == ["Source"])
    }

    @Test("returns nil for a plain host path")
    func returnsNilForPlainPath() {
        #expect(DocumentPortalResolution.parseDocumentPortalPath("/home/user/Sites/MySite.anglesite") == nil)
    }

    @Test("returns nil for a path with no doc id or name after the doc segment")
    func returnsNilForIncompletePath() {
        #expect(DocumentPortalResolution.parseDocumentPortalPath("/run/flatpak/doc") == nil)
        #expect(DocumentPortalResolution.parseDocumentPortalPath("/run/flatpak/doc/63a3dc48") == nil)
        #expect(DocumentPortalResolution.parseDocumentPortalPath("/run/user/1000/doc") == nil)
    }

    @Test("returns nil for a /run/user path whose segment after the uid isn't literally doc")
    func returnsNilForNonDocRunUserPath() {
        #expect(DocumentPortalResolution.parseDocumentPortalPath("/run/user/1000/other/63a3dc48/name") == nil)
    }

    @Test("parses a successful Info() reply's GVariant print format")
    func parsesInfoReplySuccess() {
        let reply = "(b'/home/user/Sites/MySite.anglesite', @a{sas} {})\n"
        #expect(DocumentPortalResolution.parseInfoReply(reply) == "/home/user/Sites/MySite.anglesite")
    }

    @Test("returns nil for an Info() reply with no bytestring literal")
    func parsesInfoReplyFailure() {
        #expect(DocumentPortalResolution.parseInfoReply("") == nil)
        #expect(DocumentPortalResolution.parseInfoReply("some error text") == nil)
    }

    @Test("outside a Flatpak sandbox, resolveHostPath passes the URL through unchanged")
    func resolveHostPathPassesThroughOutsideFlatpak() async throws {
        let url = URL(fileURLWithPath: "/run/flatpak/doc/63a3dc48/MySite.anglesite/Source")
        let resolved = try await DocumentPortalResolution.resolveHostPath(
            for: url, flatpakHostSpawn: false, supervisor: .shared)
        #expect(resolved == url)
    }

    @Test("a non-portal path passes through unchanged even inside a Flatpak sandbox")
    func resolveHostPathPassesThroughNonPortalPath() async throws {
        let url = URL(fileURLWithPath: "/home/user/Sites/MySite.anglesite/Source")
        let resolved = try await DocumentPortalResolution.resolveHostPath(
            for: url, flatpakHostSpawn: true, supervisor: .shared)
        #expect(resolved == url)
    }
}
#endif
