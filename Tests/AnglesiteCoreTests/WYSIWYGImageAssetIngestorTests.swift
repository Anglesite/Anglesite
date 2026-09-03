import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGImageAssetIngestor")
struct WYSIWYGImageAssetIngestorTests {
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0])

    @Test("ingests a recognized PNG into public/images and returns its root-relative path")
    func ingestsPNG() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = try WYSIWYGImageAssetIngestor.ingest(bytes: Self.pngBytes, siteDirectory: tempDir)

        #expect(path?.hasPrefix("/images/") == true)
        #expect(path?.hasSuffix(".png") == true)
        let written = tempDir.appendingPathComponent("public/images").appendingPathComponent(String(path!.dropFirst("/images/".count)))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("returns nil for unrecognized bytes instead of writing a file")
    func returnsNilForUnrecognizedFormat() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = try WYSIWYGImageAssetIngestor.ingest(bytes: Data([0x00, 0x01, 0x02]), siteDirectory: tempDir)

        #expect(path == nil)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("public/images").path))
    }

    @Test("logs the rejection for unrecognized bytes rather than dropping it silently")
    func logsUnrecognizedFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logCenter = LogCenter()
        // Subscribe *before* ingesting: the ingestor stays a synchronous API and logs from a
        // detached `Task`, so awaiting the subscription's first line is what makes this
        // deterministic — polling `snapshot()` would race that task.
        let subscription = await logCenter.subscribe()

        let path = try WYSIWYGImageAssetIngestor.ingest(
            bytes: Data([0x00, 0x01, 0x02]), siteDirectory: tempDir, logCenter: logCenter)
        #expect(path == nil)

        var iterator = subscription.stream.makeAsyncIterator()
        let line = await iterator.next()
        subscription.cancel()
        #expect(line?.source == WYSIWYGImageAssetIngestor.logSource)
        #expect(line?.stream == .stderr)
        #expect(line?.text.contains("matched no known image signature") == true)
    }

    @Test("resolves an ingested asset path back to its on-disk file under public/")
    func resolvesFileURLForAssetPath() {
        let siteDirectory = URL(fileURLWithPath: "/tmp/my-site", isDirectory: true)
        let url = WYSIWYGImageAssetIngestor.fileURL(
            forAssetPath: "/images/wysiwyg-abcd1234.jpg", siteDirectory: siteDirectory)
        #expect(url.path == "/tmp/my-site/public/images/wysiwyg-abcd1234.jpg")
    }
}
