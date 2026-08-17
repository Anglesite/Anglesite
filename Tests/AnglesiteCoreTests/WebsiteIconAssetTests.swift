import Foundation
import Testing
@testable import AnglesiteCore

@Suite("WebsiteIconAsset")
struct WebsiteIconAssetTests {
    @Test("insertHeadLinks adds standard website icon links after the head tag")
    func insertHeadLinks() {
        let source = """
        <html>
          <head>
            <title>Acme</title>
          </head>
        </html>
        """

        let patched = WebsiteIconAsset.insertHeadLinks(into: source)

        #expect(patched.contains(#"<link rel="icon" href="/favicon.ico" sizes="any" />"#))
        #expect(patched.contains(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png" />"#))
        #expect(patched.contains(#"<link rel="manifest" href="/site.webmanifest" />"#))
        #expect(patched.range(of: #"<link rel="icon" href="/favicon.ico""#)!.lowerBound <
                patched.range(of: "<title>Acme</title>")!.lowerBound)
    }

    @Test("insertHeadLinks is idempotent")
    func insertHeadLinksIsIdempotent() {
        let source = """
        <html>
          <head>
        \(WebsiteIconAsset.headLinks)
            <title>Acme</title>
          </head>
        </html>
        """

        #expect(WebsiteIconAsset.insertHeadLinks(into: source) == source)
    }

    @Test("insertHeadLinks inserts only the missing manifest link when favicon links already exist")
    func insertHeadLinksAddsOnlyMissingLink() {
        // Mirrors a post-#1525 layout: favicon.ico/favicon.png/apple-touch-icon are baked in,
        // but site.webmanifest was deliberately left out to avoid colliding with the PWA integration.
        let source = """
        <html>
          <head>
            <link rel="icon" href="/favicon.ico" sizes="any" />
            <link rel="icon" type="image/png" href="/favicon.png" />
            <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
            <title>Acme</title>
          </head>
        </html>
        """

        let patched = WebsiteIconAsset.insertHeadLinks(into: source)

        #expect(patched.contains(#"<link rel="manifest" href="/site.webmanifest" />"#))
        #expect(patched.components(separatedBy: #"href="/favicon.ico""#).count == 2)
        #expect(patched.components(separatedBy: #"href="/favicon.png""#).count == 2)
        #expect(patched.components(separatedBy: #"href="/apple-touch-icon.png""#).count == 2)
    }

    @Test("patchLayout updates an Astro layout file")
    func patchLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        let layoutDir = siteDir.appendingPathComponent("src/layouts")
        try fm.createDirectory(at: layoutDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let layoutURL = layoutDir.appendingPathComponent("BaseLayout.astro")
        try "<html><head><title>{title}</title></head></html>".write(to: layoutURL, atomically: true, encoding: .utf8)

        try WebsiteIconAsset.patchLayout(in: siteDir, fileManager: fm)

        let patched = try String(contentsOf: layoutURL, encoding: .utf8)
        #expect(patched.contains(#"href="/favicon.ico""#))
    }

    @Test("manifestData writes web app icon metadata")
    func manifestData() throws {
        let data = try WebsiteIconAsset.manifestData(siteName: #"A "Site""#)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let icons = object?["icons"] as? [[String: String]]

        #expect(object?["name"] as? String == #"A "Site""#)
        #expect(object?["short_name"] as? String == #"A "Site""#)
        #expect(object?["display"] as? String == "standalone")
        #expect(icons?.map { $0["src"] } == ["/icon-192.png", "/icon-512.png"])
    }
}
