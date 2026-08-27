import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRAssetDownloaderTests {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (status: Int, data: Data)] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.url!.absoluteString
            guard let stub = Self.responses[key] else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxr-assets-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test func downloadsEachURLIntoTheDirectory() async throws {
        StubURLProtocol.responses = ["https://example.com/a.jpg": (200, Data("A".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["https://example.com/a.jpg"], into: dir)
        #expect(result.problems.isEmpty)
        #expect(result.assets.count == 1)
        #expect(result.assets[0].sourceURL == "https://example.com/a.jpg")
        let bytes = try Data(contentsOf: dir.appendingPathComponent(result.assets[0].relativePath))
        #expect(bytes == Data("A".utf8))
    }

    @Test func duplicateURLsAreDownloadedOnce() async throws {
        StubURLProtocol.responses = ["https://example.com/a.jpg": (200, Data("A".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(
            imageURLs: ["https://example.com/a.jpg", "https://example.com/a.jpg"], into: dir)
        #expect(result.assets.count == 1)
    }

    @Test func nonHTTPStatusBecomesAProblemNotAnAsset() async throws {
        StubURLProtocol.responses = ["https://example.com/missing.jpg": (404, Data())]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["https://example.com/missing.jpg"], into: dir)
        #expect(result.assets.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func nonHTTPSchemeIsRefusedWithoutAnyRequest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["file:///etc/passwd"], into: dir)
        #expect(result.assets.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func literalPrivateAndLoopbackAddressesAreRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        for url in ["http://127.0.0.1/x.jpg", "http://10.0.0.5/x.jpg", "http://192.168.1.1/x.jpg",
                    "http://172.16.0.1/x.jpg", "http://169.254.169.254/x.jpg", "http://localhost/x.jpg"] {
            let result = await downloader.download(imageURLs: [url], into: dir)
            #expect(result.assets.isEmpty, "\(url) should have been refused")
            #expect(result.problems.count == 1, "\(url) should have produced one problem")
        }
    }

    @Test func publicIPLiteralIsAllowedThrough() async throws {
        StubURLProtocol.responses = ["http://93.184.216.34/x.jpg": (200, Data("X".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["http://93.184.216.34/x.jpg"], into: dir)
        #expect(result.assets.count == 1)
    }
}
