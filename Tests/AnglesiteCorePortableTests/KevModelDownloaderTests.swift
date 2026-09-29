// Portable-target test (pure Foundation) so the Linux CI leg executes it — see
// DecisionProviderTests for the rationale.
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

@Suite("KevModelDownloader (#2068)")
struct KevModelDownloaderTests {
    private static let base = URL(string: "https://models.example/kev-0.5b/v1/")!

    /// A published asset set: file bytes keyed by relative path, plus the manifest the convert
    /// script would write for them.
    private struct Published {
        var files: [String: Data]
        var manifestData: Data
        var manifestSHA256: String { PinnedManifestFetch.sha256Hex(manifestData) }

        static func sample(seed: UInt8 = 1) -> Published {
            var files: [String: Data] = [:]
            for (index, name) in ["vocab.json", "merges.txt", "added_tokens.json", "head.json", "head.bin",
                                  "Kev.mlmodelc/model.mil", "Kev.mlmodelc/weights/weight.bin"].enumerated() {
                files[name] = Data((0..<(64 + index * 37)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ index) })
            }
            return Published(files: files, manifestData: manifest(for: files))
        }

        static func manifest(for files: [String: Data], extra: [String: Any] = [:]) -> Data {
            var entries: [String: Any] = [:]
            for (path, data) in files {
                entries[path] = ["sha256": PinnedManifestFetch.sha256Hex(data), "bytes": data.count]
            }
            var object: [String: Any] = ["checkpoint": "kev-0.5b", "base": "Qwen/Qwen2.5-0.5B", "files": entries]
            for (key, value) in extra { object[key] = value }
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    /// Serves `published` over the transport seam; records every URL asked for.
    private actor Server {
        var files: [String: Data]
        var manifestData: Data
        var requested: [String] = []

        init(_ published: Published) {
            files = published.files
            manifestData = published.manifestData
        }

        func record(_ url: URL) { requested.append(url.absoluteString) }
        func replace(_ path: String, with data: Data) { files[path] = data }
        func remove(_ path: String) { files[path] = nil }

        func body(for url: URL) -> Data? {
            let path = url.absoluteString.replacingOccurrences(of: KevModelDownloaderTests.base.absoluteString, with: "")
            return path == "MANIFEST.json" ? manifestData : files[path]
        }

        nonisolated func transport() -> KevAssetTransport {
            { request, sink in
                let url = request.url!
                await self.record(url)
                guard let body = await self.body(for: url) else {
                    return HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                }
                // Two chunks, so the streaming hash and progress paths are exercised.
                let split = body.count / 2
                try await sink(body.prefix(split))
                try await sink(body.suffix(from: split))
                return HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        }
    }

    private actor ProgressRecorder {
        var values: [KevModelDownloadProgress] = []
        func record(_ value: KevModelDownloadProgress) { values.append(value) }
    }

    private static func temporaryParent() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KevModelDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func leftovers(in parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".kev-0.5b.") }
    }

    private static func downloader(_ published: Published, server: Server, destination: URL,
                                   manifestSHA256: String? = nil) -> KevModelDownloader {
        KevModelDownloader(
            baseURL: base, manifestPath: "MANIFEST.json", manifestSHA256: manifestSHA256 ?? published.manifestSHA256,
            destination: destination, transport: server.transport(), log: { _ in })
    }

    @Test("a verified set is staged beside the destination and moved into place; the locator then sees it")
    func installsVerifiedSet() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        let published = Published.sample()
        let server = Server(published)
        let progress = ProgressRecorder()

        let assets = try await Self.downloader(published, server: server, destination: destination)
            .install { await progress.record($0) }

        #expect(assets.directory == destination)
        #expect(assets.hasTokenizerAndHead)
        for (path, data) in published.files {
            #expect(try Data(contentsOf: destination.appendingPathComponent(path)) == data)
        }
        #expect(try Self.leftovers(in: parent).isEmpty)
        let located = KevModelLocator.installedAssets(environment: [KevModelLocator.environmentOverride: destination.path])
        #expect(located?.directory.standardizedFileURL == destination.standardizedFileURL)
        let values = await progress.values
        #expect(values.last?.fraction == 1)
        #expect(values.last?.filesCompleted == 7 && values.last?.fileCount == 7)
        #expect(values.map(\.bytesReceived) == values.map(\.bytesReceived).sorted())
        let requested = await server.requested
        #expect(requested.first == Self.base.appendingPathComponent("MANIFEST.json").absoluteString)
        #expect(requested.count == 8)
    }

    @Test("a tampered file fails the install and leaves no partial directory behind")
    func tamperedFileIsRejected() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        var published = Published.sample()
        // Same length, different bytes: the size check passes and the digest check must catch it.
        var weights = published.files["Kev.mlmodelc/weights/weight.bin"]!
        weights[3] ^= 0xff
        let server = Server(published)
        await server.replace("Kev.mlmodelc/weights/weight.bin", with: weights)
        published.files["Kev.mlmodelc/weights/weight.bin"] = weights

        await #expect(throws: KevModelDownloadError.fileDigestMismatch(path: "Kev.mlmodelc/weights/weight.bin")) {
            try await Self.downloader(published, server: server, destination: destination).install()
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.leftovers(in: parent).isEmpty)
    }

    @Test("a truncated file is reported as a size mismatch, before its digest is even compared")
    func truncatedFileIsRejected() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        let published = Published.sample()
        let server = Server(published)
        let full = published.files["head.bin"]!
        await server.replace("head.bin", with: full.prefix(full.count - 5))

        await #expect(throws: KevModelDownloadError.fileSizeMismatch(path: "head.bin", expected: Int64(full.count), actual: Int64(full.count - 5))) {
            try await Self.downloader(published, server: server, destination: destination).install()
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.leftovers(in: parent).isEmpty)
    }

    @Test("a file the host no longer has (404) fails the install")
    func missingFileIsRejected() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        let published = Published.sample()
        let server = Server(published)
        await server.remove("merges.txt")

        do {
            try await Self.downloader(published, server: server, destination: destination).install()
            Issue.record("expected fetchFailed")
        } catch KevModelDownloadError.fetchFailed(let detail) {
            #expect(detail.contains("merges.txt") && detail.contains("404"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.leftovers(in: parent).isEmpty)
    }

    @Test("a manifest that doesn't hash to the pin is discarded and no file is fetched")
    func manifestDigestMismatchStopsEverything() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        let published = Published.sample()
        let server = Server(published)
        let wrongPin = String(repeating: "0", count: 64)

        await #expect(throws: KevModelDownloadError.manifestDigestMismatch(expected: wrongPin, actual: published.manifestSHA256)) {
            try await Self.downloader(published, server: server, destination: destination, manifestSHA256: wrongPin).install()
        }
        #expect(await server.requested.count == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.leftovers(in: parent).isEmpty)
    }

    @Test("a pinned manifest with an unsafe path, a missing required file, or no backbone is refused")
    func invalidManifestsAreRefused() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)

        var traversal = Published.sample()
        traversal.files["../escape.txt"] = Data([1, 2, 3])
        traversal.manifestData = Published.manifest(for: traversal.files)
        let server = Server(traversal)
        await #expect(throws: KevModelDownloadError.invalidManifest("unsafe path ../escape.txt")) {
            try await Self.downloader(traversal, server: server, destination: destination).install()
        }
        #expect(await server.requested.count == 1)

        var noHead = Published.sample()
        noHead.files["head.bin"] = nil
        noHead.manifestData = Published.manifest(for: noHead.files)
        await #expect(throws: KevModelDownloadError.invalidManifest("missing head.bin")) {
            try await Self.downloader(noHead, server: Server(noHead), destination: destination).install()
        }

        var noBackbone = Published.sample()
        noBackbone.files = noBackbone.files.filter { !$0.key.hasPrefix("Kev.mlmodelc/") }
        noBackbone.manifestData = Published.manifest(for: noBackbone.files)
        await #expect(throws: KevModelDownloadError.invalidManifest("no Kev.mlmodelc/ entries")) {
            try await Self.downloader(noBackbone, server: Server(noBackbone), destination: destination).install()
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.leftovers(in: parent).isEmpty)
    }

    @Test("with no digest pinned nothing is fetched")
    func unconfiguredPinFetchesNothing() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let published = Published.sample()
        let server = Server(published)
        await #expect(throws: KevModelDownloadError.notConfigured) {
            try await Self.downloader(published, server: server, destination: parent.appendingPathComponent("kev-0.5b"),
                                      manifestSHA256: "").install()
        }
        #expect(await server.requested.isEmpty)
        #expect(!KevModelAssetPin.isConfigured || KevModelAssetPin.manifestSHA256.count == 64)
    }

    @Test("reinstalling replaces an earlier set wholesale, and remove(at:) takes it away again")
    func replaceAndRemove() async throws {
        let parent = try Self.temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("kev-0.5b", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stale = destination.appendingPathComponent("stale.bin")
        try Data([9, 9, 9]).write(to: stale)

        let published = Published.sample(seed: 7)
        try await Self.downloader(published, server: Server(published), destination: destination).install()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("vocab.json")) == published.files["vocab.json"])
        #expect(try Self.leftovers(in: parent).isEmpty)

        try KevModelDownloader.remove(at: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(KevModelLocator.installedAssets(environment: [KevModelLocator.environmentOverride: destination.path]) == nil)
        try KevModelDownloader.remove(at: destination)  // idempotent
    }
}
