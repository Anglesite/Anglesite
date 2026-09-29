import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Streams one HTTP response body to `sink` chunk by chunk and returns the response. The seam
/// ``KevModelDownloader`` fetches through, so tests hand it canned bytes and the app hands it
/// `URLSession` (``KevModelDownloader/defaultTransport``). The transport never sees where the
/// bytes go: hashing, size accounting and the staging file are the downloader's.
public typealias KevAssetTransport = @Sendable (
    _ request: URLRequest, _ sink: @Sendable (Data) async throws -> Void
) async throws -> HTTPURLResponse

/// `MANIFEST.json` as `scripts/kev/convert-kev-coreml.py` writes it: every asset file, keyed by
/// its path relative to the asset directory, with its SHA-256 and size. Other manifest fields
/// (base model, adapter digest, tool versions) are informational and ignored here.
public struct KevAssetManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Lowercase-hex SHA-256 of the file's bytes.
        public let sha256: String
        /// The file's size in bytes.
        public let bytes: Int64

        public init(sha256: String, bytes: Int64) {
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public let files: [String: Entry]

    public init(files: [String: Entry]) {
        self.files = files
    }

    /// Sum of every listed file's size — the denominator for download progress.
    public var totalBytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }

    /// Relative paths in a stable order, so a run always downloads the same way.
    public var orderedPaths: [String] { files.keys.sorted() }

    /// Rejects a manifest the downloader must not act on: a path that could escape the staging
    /// directory (absolute, `..`, empty component), a malformed digest or size, a set missing
    /// the tokenizer/head files ``KevModelAssets/hasTokenizerAndHead`` requires, or one with no
    /// compiled backbone under `Kev.mlmodelc/` at all. The manifest's own digest was already
    /// verified against the pin before this runs; this guards against a *pinned* manifest that
    /// is simply wrong, which would otherwise install a directory the locator accepts but the
    /// scorer can't use.
    public func validate() throws {
        guard !files.isEmpty else { throw KevModelDownloadError.invalidManifest("no files listed") }
        for (path, entry) in files {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.contains(""), !components.contains(".."), !components.contains(".") else {
                throw KevModelDownloadError.invalidManifest("unsafe path \(path)")
            }
            guard entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw KevModelDownloadError.invalidManifest("malformed digest for \(path)")
            }
            guard entry.bytes >= 0 else { throw KevModelDownloadError.invalidManifest("negative size for \(path)") }
        }
        // A key that is also an ancestor directory of another key can't be both a file and a
        // directory on disk; say so here rather than as a createDirectory error mid-download.
        for path in files.keys {
            var ancestor = Substring(path)
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = ancestor[..<slash]
                if files[String(ancestor)] != nil {
                    throw KevModelDownloadError.invalidManifest("path collision: \(ancestor) is listed as a file and used as a directory")
                }
            }
        }
        let probe = KevModelAssets(directory: URL(fileURLWithPath: "/"))
        let required = [probe.vocabURL, probe.mergesURL, probe.addedTokensURL, probe.headMetadataURL, probe.headWeightsURL]
            .map(\.lastPathComponent)
        for name in required where files[name] == nil {
            throw KevModelDownloadError.invalidManifest("missing \(name)")
        }
        let backbone = probe.backboneURL.lastPathComponent + "/"
        guard files.keys.contains(where: { $0.hasPrefix(backbone) }) else {
            throw KevModelDownloadError.invalidManifest("no \(backbone) entries")
        }
    }
}

/// Why an install produced no model. Every case leaves ``KevModelLocator/defaultDirectory(fileManager:)``
/// exactly as it was: nothing is moved into place until the whole set has verified.
public enum KevModelDownloadError: Error, Equatable, Sendable {
    /// ``KevModelAssetPin/isConfigured`` is `false`: no digest to verify against, so nothing is
    /// fetched at all.
    case notConfigured
    /// The HTTP fetch of the named URL didn't produce a 2xx response, or the transport failed.
    case fetchFailed(String)
    /// The manifest arrived but its bytes don't hash to the pinned digest. Discarded unread.
    case manifestDigestMismatch(expected: String, actual: String)
    /// The manifest verified but can't be acted on — see ``KevAssetManifest/validate()``.
    case invalidManifest(String)
    /// A downloaded file's size differs from the manifest's.
    case fileSizeMismatch(path: String, expected: Int64, actual: Int64)
    /// The host kept sending past the manifest's size for this file; the transfer was stopped
    /// there rather than allowed to fill the disk.
    case fileExceedsManifestSize(path: String, expected: Int64)
    /// The volume holding the destination has less free space than the manifest's total.
    case insufficientDiskSpace(required: Int64, available: Int64)
    /// A downloaded file's bytes don't hash to the manifest's digest for it.
    case fileDigestMismatch(path: String)
    /// Everything verified but the staging directory couldn't be moved into place.
    case installFailed(String)
}

/// Where an install is, for the owner-facing "Downloading…" state. Owner surfaces show a bar
/// from ``fraction``; the byte counts go to the Debug pane.
public struct KevModelDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    public let bytesExpected: Int64
    public let filesCompleted: Int
    public let fileCount: Int

    public init(bytesReceived: Int64, bytesExpected: Int64, filesCompleted: Int, fileCount: Int) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.filesCompleted = filesCompleted
        self.fileCount = fileCount
    }

    /// 0…1; `1` only once every file is on disk.
    public var fraction: Double {
        guard bytesExpected > 0 else { return filesCompleted == fileCount ? 1 : 0 }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }
}

/// Download-on-demand for the Kev-0.5B assets (#2068): fetch the pinned manifest, verify it,
/// download and verify every file it lists into a staging directory beside the destination, then
/// move the staging directory into place in one rename. A half-written set therefore never sits
/// where ``KevModelLocator`` looks, and a tampered or truncated file fails the whole install
/// with the staging directory removed. Progress and every failure go to `log` (the Debug pane);
/// the owner-facing states are the app model's concern.
public struct KevModelDownloader: Sendable {
    public let baseURL: URL
    public let manifestPath: String
    public let manifestSHA256: String
    public let destination: URL
    private let fileManager: FileManager
    private let transport: KevAssetTransport
    private let log: @Sendable (String) async -> Void

    /// - Parameters:
    ///   - baseURL: Versioned prefix the files are served under (``KevModelAssetPin/baseURL``).
    ///   - manifestPath: Manifest file name under `baseURL`.
    ///   - manifestSHA256: The pinned digest the manifest bytes must hash to; empty means
    ///     ``KevModelDownloadError/notConfigured``.
    ///   - destination: The asset directory to install into
    ///     (``KevModelLocator/defaultDirectory(fileManager:)`` in the app). Its parent must be
    ///     writable: staging happens beside it so the final move is a same-volume rename.
    ///   - fileManager: Injectable for tests.
    ///   - transport: The HTTP seam; ``defaultTransport`` in the app.
    ///   - log: Where progress and failures are reported; `LogCenter` by default.
    public init(
        baseURL: URL = KevModelAssetPin.baseURL,
        manifestPath: String = KevModelAssetPin.manifestPath,
        manifestSHA256: String = KevModelAssetPin.manifestSHA256,
        destination: URL,
        fileManager: FileManager = .default,
        transport: @escaping KevAssetTransport = KevModelDownloader.defaultTransport,
        log: (@Sendable (String) async -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.destination = destination
        self.fileManager = fileManager
        self.transport = transport
        self.log = log ?? { text in
            await LogCenter.shared.append(source: "KevModelDownloader", stream: .stdout, text: text)
        }
    }

    /// The app's downloader over ``KevModelAssetPin`` into the default asset directory, or `nil`
    /// when this platform has no Application Support directory.
    public static func makeDefault(fileManager: FileManager = .default) -> KevModelDownloader? {
        KevModelLocator.defaultDirectory(fileManager: fileManager).map {
            KevModelDownloader(destination: $0, fileManager: fileManager)
        }
    }

    /// One `URLSessionDataTask` whose body reaches `sink` as the whole `Data` chunks the
    /// session's delegate receives — never a per-byte `AsyncBytes` walk, which costs ~10⁹
    /// iterations for the backbone. Cancelling the awaiting Swift task cancels the transfer, and
    /// the delegate shape is the one a background-configured session would plug into later.
    public static let defaultTransport: KevAssetTransport = { request, sink in
        let delegate = ChunkedDataTaskDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        try await withTaskCancellationHandler {
            for try await chunk in delegate.chunks { try await sink(chunk) }
        } onCancel: {
            task.cancel()
        }
        guard let http = delegate.httpResponse else {
            throw KevModelDownloadError.fetchFailed("non-HTTP response from \(request.url?.absoluteString ?? "?")")
        }
        return http
    }

    /// Runs the whole install. Returns the installed assets on success; on any failure the
    /// staging directory is removed, `destination` is untouched, and the error is thrown after
    /// being logged.
    ///
    /// - Parameter progress: Called after each chunk and each completed file; owner surfaces
    ///   read ``KevModelDownloadProgress/fraction`` from it.
    @discardableResult
    public func install(progress: (@Sendable (KevModelDownloadProgress) async -> Void)? = nil) async throws -> KevModelAssets {
        do {
            return try await installOrThrow(progress: progress)
        } catch is CancellationError {
            await log("Screening model download cancelled; nothing installed")
            throw CancellationError()
        } catch {
            await log("Screening model install failed: \(error)")
            throw error
        }
    }

    /// Deletes an installed asset directory (the Settings "Remove" action). Missing is success.
    public static func remove(at directory: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// Removes staging (`.<name>.download-*`) and swapped-out (`.<name>.replaced-*`) siblings of
    /// `destination` left by an install that never got to clean up — a quit mid-download, a
    /// crash, power loss. Each is up to the full asset size, so this runs at the start of every
    /// install and whenever the app re-probes the model directory. Never touches `destination`.
    public static func sweepLeftovers(besides destination: URL, fileManager: FileManager = .default) {
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard let siblings = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return }
        for sibling in siblings where sibling.hasPrefix(".\(name).download-") || sibling.hasPrefix(".\(name).replaced-") {
            try? fileManager.removeItem(at: parent.appendingPathComponent(sibling))
        }
    }

    // MARK: - Steps

    private func installOrThrow(progress: (@Sendable (KevModelDownloadProgress) async -> Void)?) async throws -> KevModelAssets {
        guard manifestSHA256.count == 64 else { throw KevModelDownloadError.notConfigured }

        let manifest = try await fetchManifest()
        try manifest.validate()
        let paths = manifest.orderedPaths
        let expected = manifest.totalBytes
        await log("Screening model: manifest verified, \(paths.count) files, \(expected) bytes")

        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        Self.sweepLeftovers(besides: destination, fileManager: fileManager)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: parent.path),
           let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value, free < expected {
            throw KevModelDownloadError.insufficientDiskSpace(required: expected, available: free)
        }
        let staging = parent.appendingPathComponent(".\(name).download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var installed = false
        defer { if !installed { try? fileManager.removeItem(at: staging) } }

        var received: Int64 = 0
        for (index, path) in paths.enumerated() {
            let entry = manifest.files[path]!
            let target = staging.appendingPathComponent(path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = received
            let written = try await download(
                baseURL.appendingPathComponent(path), to: target, path: path, limit: entry.bytes) { bytesSoFar in
                    guard let progress else { return }
                    await progress(KevModelDownloadProgress(
                        bytesReceived: base + bytesSoFar, bytesExpected: expected,
                        filesCompleted: index, fileCount: paths.count))
                }
            guard written.bytes == entry.bytes else {
                throw KevModelDownloadError.fileSizeMismatch(path: path, expected: entry.bytes, actual: written.bytes)
            }
            guard written.sha256 == entry.sha256 else { throw KevModelDownloadError.fileDigestMismatch(path: path) }
            received += written.bytes
            await progress?(KevModelDownloadProgress(
                bytesReceived: received, bytesExpected: expected, filesCompleted: index + 1, fileCount: paths.count))
        }

        let assets = KevModelAssets(directory: staging)
        guard assets.hasTokenizerAndHead(fileManager: fileManager) else {
            throw KevModelDownloadError.installFailed("staged set is missing tokenizer/head files")
        }
        try moveIntoPlace(from: staging, parent: parent, name: name)
        installed = true
        await log("Screening model installed at \(destination.path) (\(received) bytes)")
        return KevModelAssets(directory: destination)
    }

    /// Manifests are a few KB; anything past this is not the manifest.
    static let manifestByteLimit = 1 << 20

    private func fetchManifest() async throws -> KevAssetManifest {
        let url = baseURL.appendingPathComponent(manifestPath)
        let collector = ByteCollector()
        let response = try await transport(URLRequest(url: url)) { chunk in
            guard await collector.data.count + chunk.count <= Self.manifestByteLimit else {
                throw KevModelDownloadError.fetchFailed("\(url.absoluteString): manifest larger than \(Self.manifestByteLimit) bytes")
            }
            await collector.append(chunk)
        }
        guard 200..<300 ~= response.statusCode else {
            throw KevModelDownloadError.fetchFailed("\(url.absoluteString) → HTTP \(response.statusCode)")
        }
        let data = await collector.data
        let actual = PinnedManifestFetch.sha256Hex(data)
        guard actual == manifestSHA256 else {
            throw KevModelDownloadError.manifestDigestMismatch(expected: manifestSHA256, actual: actual)
        }
        do {
            return try JSONDecoder().decode(KevAssetManifest.self, from: data)
        } catch {
            throw KevModelDownloadError.invalidManifest("undecodable: \(error)")
        }
    }

    /// Streams one file to `target`, hashing and counting as it goes, and stops the transfer the
    /// moment it passes `limit` (the manifest's size) so a misbehaving host can't fill the disk
    /// before the size check. Cancellation surfaces as `CancellationError`, never as a fetch
    /// failure, so the app can tell "the owner stopped it" from "it broke".
    private func download(
        _ url: URL, to target: URL, path: String, limit: Int64,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (bytes: Int64, sha256: String) {
        guard fileManager.createFile(atPath: target.path, contents: nil) else {
            throw KevModelDownloadError.installFailed("couldn't create \(target.path)")
        }
        let handle = try FileHandle(forWritingTo: target)
        let sink = FileSink(handle: handle)
        let response: HTTPURLResponse
        do {
            response = try await transport(URLRequest(url: url)) { chunk in
                guard await sink.count + Int64(chunk.count) <= limit else {
                    throw KevModelDownloadError.fileExceedsManifestSize(path: path, expected: limit)
                }
                try await sink.write(chunk)
                await onProgress(await sink.count)
            }
        } catch let error as KevModelDownloadError {
            try? handle.close()
            throw error
        } catch is CancellationError {
            try? handle.close()
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            try? handle.close()
            throw CancellationError()
        } catch {
            try? handle.close()
            throw KevModelDownloadError.fetchFailed("\(url.absoluteString): \(error)")
        }
        try handle.close()
        guard 200..<300 ~= response.statusCode else {
            throw KevModelDownloadError.fetchFailed("\(url.absoluteString) → HTTP \(response.statusCode)")
        }
        return await (sink.count, sink.finalizeHex())
    }

    private func moveIntoPlace(from staging: URL, parent: URL, name: String) throws {
        let previous = parent.appendingPathComponent(".\(name).replaced-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        do {
            if hadPrevious { try fileManager.moveItem(at: destination, to: previous) }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hadPrevious, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: previous, to: destination)
            }
            throw KevModelDownloadError.installFailed("\(error)")
        }
        if hadPrevious { try? fileManager.removeItem(at: previous) }
    }
}

/// Receives one data task's body as delegate-delivered `Data` chunks and republishes them as an
/// `AsyncThrowingStream`, finishing with the task's error (a cancelled task ends in
/// `URLError.cancelled`, which the downloader maps to `CancellationError`). Chunks are buffered
/// unboundedly between arrival and the sink's disk write; disk is faster than the network in
/// practice, and the per-file size bound still caps what a run can hold.
private final class ChunkedDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var response: HTTPURLResponse?
    let chunks: AsyncThrowingStream<Data, Error>

    override init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        chunks = AsyncThrowingStream { captured = $0 }
        super.init()
        continuation = captured
    }

    var httpResponse: HTTPURLResponse? {
        lock.lock(); defer { lock.unlock() }
        return response
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }
}

/// Gathers a small body (the manifest) in memory.
private actor ByteCollector {
    var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
}

/// Writes chunks to a file while hashing and counting them, so a 1 GB body is never held.
private actor FileSink {
    private let handle: FileHandle
    private var hasher = StreamingSHA256()
    private(set) var count: Int64 = 0

    init(handle: FileHandle) { self.handle = handle }

    func write(_ chunk: Data) throws {
        try handle.write(contentsOf: chunk)
        hasher.update(chunk)
        count += Int64(chunk.count)
    }

    func finalizeHex() -> String { hasher.finalizeHex() }
}

/// Incremental SHA-256: CryptoKit on Darwin; on the Linux `AnglesiteCore` build the vendored
/// `PortableSHA256` has no streaming API, so the bytes are accumulated — that build only ever
/// hashes test fixtures.
private struct StreamingSHA256 {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalizeHex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var buffer = Data()
    mutating func update(_ data: Data) { buffer.append(data) }
    func finalizeHex() -> String { PortableSHA256.hexDigest(of: buffer) }
    #endif
}
