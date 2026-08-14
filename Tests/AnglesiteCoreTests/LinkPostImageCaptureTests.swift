import Foundation
import Testing
@testable import AnglesiteCore

/// Byte prefixes for the formats ``LinkImageAsset/format(sniffing:)`` recognizes, plus the ones it
/// must refuse. Padded past every signature length so a real sniff has enough bytes to look at.
private enum ImageFixture {
    static func padded(_ prefix: [UInt8]) -> Data {
        Data(prefix + [UInt8](repeating: 0x00, count: 32))
    }
    static let jpeg = padded([0xFF, 0xD8, 0xFF, 0xE0])
    static let png = padded([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let gif = padded(Array("GIF89a".utf8))
    static let webp = padded(Array("RIFF".utf8) + [0x10, 0x00, 0x00, 0x00] + Array("WEBP".utf8))
    static let avif = padded([0x00, 0x00, 0x00, 0x20] + Array("ftyp".utf8) + Array("avif".utf8))
    static let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>"#.utf8)
    static let html = Data("<!doctype html><html><body>404</body></html>".utf8)
}

/// A bookmark entry exactly as `ContentScaffold.renderEntry` writes one, so the patch tests run
/// against the real shape rather than a hand-simplified stand-in.
private let bookmarkEntry = """
---
lang: ""
bookmarkOf: "https://example.com/interesting-thing"
title: "Interesting Thing"
publishDate: 2026-08-13T20:00:00.000Z
tags: []
draft: true
---

Two sentences of commentary.

"""

@Suite("LinkImageAsset")
struct LinkImageAssetTests {
    @Test("format is sniffed from the bytes, not the URL or Content-Type")
    func sniffing() {
        #expect(LinkImageAsset.format(sniffing: ImageFixture.jpeg) == .jpeg)
        #expect(LinkImageAsset.format(sniffing: ImageFixture.png) == .png)
        #expect(LinkImageAsset.format(sniffing: ImageFixture.gif) == .gif)
        #expect(LinkImageAsset.format(sniffing: ImageFixture.webp) == .webp)
        #expect(LinkImageAsset.format(sniffing: ImageFixture.avif) == .avif)
    }

    @Test("SVG, HTML, empty and truncated payloads are refused")
    func refusedPayloads() {
        // SVG is a script-execution vector once served from the owner's own origin.
        #expect(LinkImageAsset.format(sniffing: ImageFixture.svg) == nil)
        #expect(LinkImageAsset.format(sniffing: ImageFixture.html) == nil)
        #expect(LinkImageAsset.format(sniffing: Data()) == nil)
        // A RIFF container that isn't WEBP, and a signature cut short, must not sniff as an image.
        #expect(LinkImageAsset.format(sniffing: ImageFixture.padded(Array("RIFFxxxxAVI ".utf8))) == nil)
        #expect(LinkImageAsset.format(sniffing: Data([0xFF, 0xD8])) == nil)
    }

    @Test("paths derive from the entry slug and the sniffed format")
    func paths() {
        #expect(LinkImageAsset.fileName(slug: "interesting-thing", format: .jpeg) == "link-interesting-thing.jpg")
        #expect(LinkImageAsset.assetRelativePath(slug: "a-post", format: .png) == "public/images/link-a-post.png")
        #expect(LinkImageAsset.publicURLPath(slug: "a-post", format: .png) == "/images/link-a-post.png")
    }

    @Test("install writes into public/images, creating it, and overwrites a re-capture")
    func install() throws {
        let site = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }

        let relPath = try LinkImageAsset.install(
            bytes: ImageFixture.png, format: .png, slug: "post", siteDirectory: site)
        #expect(relPath == "public/images/link-post.png")
        let written = site.appendingPathComponent(relPath)
        #expect(try Data(contentsOf: written) == ImageFixture.png)

        // Same slug + format ⇒ same file, replaced rather than accumulated.
        let bigger = ImageFixture.png + Data([0x01, 0x02, 0x03])
        _ = try LinkImageAsset.install(bytes: bigger, format: .png, slug: "post", siteDirectory: site)
        #expect(try Data(contentsOf: written) == bigger)
        let listed = try FileManager.default.contentsOfDirectory(
            atPath: site.appendingPathComponent("public/images").path)
        #expect(listed == ["link-post.png"])
    }
}

@Suite("LinkPostImageCapture")
struct LinkPostImageCaptureTests {
    /// A site directory containing one written bookmark entry, mimicking the state `createTyped`
    /// leaves behind — which is the only state `capture` ever runs against.
    private struct Fixture {
        let site: URL
        let entryRelativePath = "src/content/bookmarks/interesting-thing.md"
        var entryURL: URL { site.appendingPathComponent(entryRelativePath) }

        init() throws {
            site = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmarkEntry.write(to: entryURL, atomically: true, encoding: .utf8)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: site) }
        func entryText() throws -> String { try String(contentsOf: entryURL, encoding: .utf8) }
        var imageURL: URL { site.appendingPathComponent("public/images/link-interesting-thing.png") }
    }

    /// Records what the capture asked git to stage, so the "one commit, both paths" contract is
    /// observable without a real repository.
    private final class CommitRecorder: @unchecked Sendable {
        private(set) var paths: [String] = []
        private(set) var messages: [String] = []
        var commit: LinkPostImageCapture.GitCommit {
            { [self] _, relPaths, message in
                paths = relPaths
                messages.append(message)
                return "deadbeef"
            }
        }
    }

    private func transport(
        _ data: Data, status: Int = 200, finalURL: String = "https://cdn.example.com/card.png"
    ) -> LinkPostImageCapture.Transport {
        { _ in
            let response = HTTPURLResponse(
                url: URL(string: finalURL)!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }
    }

    @Test("happy path: image installed, referenced from frontmatter, both staged in one commit")
    func capturesImage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recorder = CommitRecorder()
        let capture = LinkPostImageCapture(
            transport: transport(ImageFixture.png), gitCommit: recorder.commit)

        let path = await capture.capture(
            imageURL: URL(string: "https://cdn.example.com/card.png")!,
            entryRelativePath: fixture.entryRelativePath,
            slug: "interesting-thing",
            siteDirectory: fixture.site)

        #expect(path == "/images/link-interesting-thing.png")
        #expect(try Data(contentsOf: fixture.imageURL) == ImageFixture.png)

        let patched = try fixture.entryText()
        #expect(patched.contains(#"image: "/images/link-interesting-thing.png""#))
        // Everything the owner wrote survives verbatim — the commentary body and every other key.
        #expect(patched.contains("Two sentences of commentary."))
        #expect(patched.contains(#"bookmarkOf: "https://example.com/interesting-thing""#))
        #expect(patched.contains("draft: true"))

        // One commit, entry and image together: a clone must never see an entry whose image
        // isn't in the same tree.
        #expect(recorder.messages == ["anglesite: add card image for interesting-thing"])
        #expect(Set(recorder.paths) == [
            "public/images/link-interesting-thing.png", fixture.entryRelativePath,
        ])
    }

    @Test("every refusal leaves the entry exactly as created, with no file and no commit")
    func refusalsAreNoOps() async throws {
        let cases: [(String, LinkPostImageCapture.Transport)] = [
            ("404", transport(ImageFixture.png, status: 404)),
            ("SVG payload", transport(ImageFixture.svg)),
            ("HTML error page served as an image", transport(ImageFixture.html)),
            ("over the byte cap", transport(
                ImageFixture.png + Data(repeating: 0x00, count: LinkImageAsset.maximumImageBytes))),
            ("redirected to a non-web scheme", transport(
                ImageFixture.png, finalURL: "file:///etc/passwd")),
        ]
        for (label, stub) in cases {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let recorder = CommitRecorder()
            let capture = LinkPostImageCapture(transport: stub, gitCommit: recorder.commit)

            let path = await capture.capture(
                imageURL: URL(string: "https://cdn.example.com/card.png")!,
                entryRelativePath: fixture.entryRelativePath,
                slug: "interesting-thing",
                siteDirectory: fixture.site)

            #expect(path == nil, "\(label) should not produce a card image")
            #expect(try fixture.entryText() == bookmarkEntry, "\(label) must not touch the entry")
            #expect(!FileManager.default.fileExists(atPath: fixture.imageURL.path), "\(label)")
            #expect(recorder.messages.isEmpty, "\(label) must not commit")
        }
    }

    @Test("a non-http(s) og:image is never fetched")
    func rejectsNonWebScheme() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = LinkPostImageCapture(
            transport: { _ in
                Issue.record("the transport must not be reached for a non-web scheme")
                throw LinkImageError.unsupportedScheme
            },
            gitCommit: { _, _, _ in nil })
        let path = await capture.capture(
            imageURL: URL(string: "file:///etc/passwd")!,
            entryRelativePath: fixture.entryRelativePath,
            slug: "interesting-thing", siteDirectory: fixture.site)
        #expect(path == nil)
        #expect(try fixture.entryText() == bookmarkEntry)
    }

    @Test("the convenience overload no-ops without an image, a created entry, or a site directory")
    func convenienceGuards() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = LinkPostImageCapture(
            transport: { _ in
                Issue.record("the transport must not be reached when there is nothing to capture")
                throw LinkImageError.unsupportedScheme
            },
            gitCommit: { _, _, _ in nil })
        let created = ContentCreateResult.created(
            filePath: fixture.entryRelativePath, identifier: "interesting-thing")

        #expect(await capture.capture(
            imageURL: nil, createResult: created, siteDirectory: fixture.site) == nil)
        #expect(await capture.capture(
            imageURL: "https://cdn.example.com/card.png",
            createResult: .failed(reason: "already exists"), siteDirectory: fixture.site) == nil)
        #expect(await capture.capture(
            imageURL: "https://cdn.example.com/card.png",
            createResult: created, siteDirectory: nil) == nil)
    }

    @Test("patched adds image without disturbing anything else, and replaces an existing value")
    func patching() {
        let once = LinkPostImageCapture.patched(entryText: bookmarkEntry, imagePath: "/images/a.png")
        #expect(once?.contains(#"image: "/images/a.png""#) == true)
        // Round-trip identity for everything untouched: only the added line differs.
        let addedLines = Set((once ?? "").split(separator: "\n", omittingEmptySubsequences: false))
            .subtracting(bookmarkEntry.split(separator: "\n", omittingEmptySubsequences: false))
        #expect(addedLines == [#"image: "/images/a.png""#])

        // A re-capture replaces the value rather than adding a duplicate key.
        let twice = LinkPostImageCapture.patched(entryText: once ?? "", imagePath: "/images/b.jpg")
        #expect(twice?.contains(#"image: "/images/b.jpg""#) == true)
        #expect(twice?.contains("/images/a.png") == false)
        #expect((twice ?? "").components(separatedBy: "image:").count == 2)
    }

    @Test("patched refuses a file with no frontmatter block rather than rewriting it")
    func patchingRefusesBodyOnly() {
        #expect(LinkPostImageCapture.patched(entryText: "Just a body.\n", imagePath: "/images/a.png") == nil)
    }
}
