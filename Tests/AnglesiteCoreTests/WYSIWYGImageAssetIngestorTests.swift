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
}
