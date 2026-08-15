import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Captures a link post's `og:image` into the site's assets and references it from the entry's
/// frontmatter (#1451, follow-up 2 of the quick-capture spec's §8).
///
/// Runs **after** the entry is written, deliberately:
///
/// - The slug the image file is named for is the one `createTyped` actually derived, not a
///   re-derivation of it that could drift from the real thing.
/// - `createTyped` refuses to overwrite an existing entry; running afterwards means a refused
///   capture never leaves a downloaded image behind, nor overwrites another entry's image.
/// - Every failure here is a no-op on an already-complete link post. That is the spec's
///   best-effort rule (§6, same as the title fetch): the bookmark is the deliverable, the card
///   image is a bonus, and a hostile or merely broken `og:image` must not cost the owner the post.
///
/// The `image:` key is added by patching the written file rather than by passing a field value
/// into `ContentScaffold.renderEntry`, because `renderEntry` only emits fields the descriptor
/// declares — declaring `image` on `bookmark` would put a dead `image: ""` line in every
/// hand-made bookmark, captured or not.
public struct LinkPostImageCapture: Sendable {
    /// Fetch seam so tests serve canned bytes with no network. An injected transport is still held
    /// to the byte cap after the fact — only the default transport can abort mid-stream.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Stage-and-commit seam. Multi-path (unlike `NativeContentOperations.GitCommit`) because the
    /// image and the entry that references it belong in **one** commit — a clone must never see an
    /// entry pointing at an image that isn't in the same tree.
    public typealias GitCommit = @Sendable (_ projectRoot: URL, _ relPaths: [String], _ message: String) async -> String?

    /// Idle timeout: the longest the transfer may go without progress.
    public static let timeout: TimeInterval = 10
    /// Wall-clock deadline for the whole transfer — see `CappedHTTPTransport` for why an idle
    /// timeout alone is not a bound a slow-drip server has to respect.
    public static let resourceTimeout: TimeInterval = 20

    private let transport: Transport
    private let gitCommit: GitCommit
    // `nonisolated(unsafe)` for the same reason `NativeContentOperations` uses it: FileManager is
    // a thread-safe singleton that only recent SDKs declare `Sendable`, and this keeps the
    // test-injection seam without making the struct's `Sendable` conformance toolchain-dependent.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(
        transport: @escaping Transport = LinkPostImageCapture.defaultTransport,
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommitPaths,
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.gitCommit = gitCommit
        self.fileManager = fileManager
    }

    /// Convenience over ``capture(imageURL:entryRelativePath:slug:siteDirectory:)`` for the create
    /// call sites: takes the metadata's raw `og:image` string and the `createTyped` result, and
    /// no-ops unless there is both an image to fetch and an entry to attach it to.
    public func capture(
        imageURL: String?, createResult: ContentCreateResult, siteDirectory: URL?
    ) async -> String? {
        guard case let .created(filePath, identifier) = createResult,
              let siteDirectory,
              let imageURL, let url = URL(string: imageURL)
        else { return nil }
        return await capture(
            imageURL: url, entryRelativePath: filePath, slug: identifier,
            siteDirectory: siteDirectory)
    }

    /// Downloads `imageURL`, installs it under `public/images/`, adds `image:` to the entry's
    /// frontmatter, and commits both in one commit. Returns the root-relative served path on
    /// success, or nil on any failure — logged to the debug pane, never thrown at the caller.
    public func capture(
        imageURL: URL, entryRelativePath: String, slug: String, siteDirectory: URL
    ) async -> String? {
        let bytes: Data
        let format: LinkImageAsset.Format
        do {
            (bytes, format) = try await download(imageURL)
        } catch {
            await log("no card image for \(slug): \(imageURL.absoluteString) — \(error)")
            return nil
        }

        let assetPath: String
        do {
            assetPath = try LinkImageAsset.install(
                bytes: bytes, format: format, slug: slug,
                siteDirectory: siteDirectory, fileManager: fileManager)
        } catch {
            await log("couldn't save the card image for \(slug): \(error)")
            return nil
        }

        let publicPath = LinkImageAsset.publicURLPath(slug: slug, format: format)
        let entryURL = siteDirectory.appendingPathComponent(entryRelativePath)
        do {
            let source = try String(contentsOf: entryURL, encoding: .utf8)
            guard let patched = Self.patched(entryText: source, imagePath: publicPath) else {
                throw LinkImageError.entryNotPatchable
            }
            try patched.write(to: entryURL, atomically: true, encoding: .utf8)
        } catch {
            // The entry is already written and committed; leaving an image nothing references
            // would just be a dead asset, so undo the install rather than keep it.
            try? fileManager.removeItem(at: siteDirectory.appendingPathComponent(assetPath))
            await log("couldn't reference the card image from \(entryRelativePath): \(error)")
            return nil
        }

        // Best-effort, exactly like the create path's own commit: an uncommitted asset still
        // deploys (deploy tars `Source/`), and the owner's next commit picks it up.
        _ = await gitCommit(siteDirectory, [assetPath, entryRelativePath],
                            "anglesite: add card image for \(slug)")
        return publicPath
    }

    /// `entryText` with `image: "<imagePath>"` added to (or replaced in) its frontmatter, or nil
    /// when there is no frontmatter block to patch.
    ///
    /// Goes through `FrontmatterDocument`, so every other key, the comments, and the body all
    /// round-trip byte-for-byte — the commentary the owner just typed is not re-rendered.
    public static func patched(entryText: String, imagePath: String) -> String? {
        var document = FrontmatterDocument.parse(entryText)
        document.set(.string(imagePath), for: "image")
        let serialized = document.serialized()
        // A file with no `---` fence serializes back to its body alone, silently dropping the
        // `set` above; refuse rather than rewrite the entry without the key it was asked to add.
        guard serialized.contains(imagePath) else { return nil }
        return serialized
    }

    /// Fetches the image bytes under the full guard set — http(s) (including post-redirect), byte
    /// cap, deadlines — and sniffs the format. Throws ``LinkImageError`` for guard violations;
    /// transport errors propagate as-is.
    func download(_ url: URL) async throws -> (Data, LinkImageAsset.Format) {
        guard Self.isWebScheme(url) else { throw LinkImageError.unsupportedScheme }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout

        let (data, http) = try await transport(request)

        // URLSession follows redirects transparently, so re-check where the bytes actually came
        // from: an https `og:image` that redirects to `file:` is not an https image.
        if let finalURL = http.url, !Self.isWebScheme(finalURL) {
            throw LinkImageError.unsupportedScheme
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinkImageError.requestFailed(status: http.statusCode)
        }
        // The default transport already aborts mid-stream past the cap; this re-check holds an
        // injected transport to the same limit.
        guard data.count <= LinkImageAsset.maximumImageBytes else {
            throw LinkImageError.responseTooLarge(data.count)
        }
        guard let format = LinkImageAsset.format(sniffing: data) else {
            throw LinkImageError.unsupportedFormat
        }
        return (data, format)
    }

    static func isWebScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private func log(_ text: String) async {
        await LogCenter.shared.append(source: "quick-capture:image", stream: .stderr, text: text)
    }

    static let session = CappedHTTPTransport.session(
        requestTimeout: timeout, resourceTimeout: resourceTimeout)

    /// Production transport: streams so the cap is enforced *during* transfer, on an ephemeral
    /// session (no cookies, no shared-cache pollution) carrying the wall-clock deadline.
    public static let defaultTransport: Transport = { request in
        try await CappedHTTPTransport.fetch(
            request,
            session: LinkPostImageCapture.session,
            cap: LinkImageAsset.maximumImageBytes,
            tooLarge: LinkImageError.responseTooLarge)
    }
}
