// Sources/AnglesiteApp/RestrictedPostPublisher.swift
import Foundation
import AnglesiteCore
import AnglesiteIOS

/// The composer-facing outcome of a create attempt — deliberately smaller than
/// `ContentCreateResult`: the sheet only needs to know whether to dismiss or show an error,
/// never a created file's path/identifier (that bookkeeping is `SiteWindowModel`'s own concern,
/// already handled before this value is returned). See design doc §5.4 for why this isn't a new
/// `ContentCreateResult` case.
enum ComposerCreateOutcome: Equatable {
    case success
    case siteNotFound
    case failed(reason: String)
}

/// Publishes a new restricted (`visibility: contacts`) post straight to the site's Micropub
/// endpoint — the Mac composer's only Micropub-write path today (#1566); everything else on Mac
/// still writes through `NativeContentOperations`. Uses ``MicropubSessionResolver`` (the same
/// resolution `TypedEntryEditorModel`'s CMS-mode save path uses) so both stay unit-testable
/// without a real Keychain/network.
struct RestrictedPostPublisher {
    private let makeMicropubClient: MicropubSessionResolver.Factory

    init(makeMicropubClient: @escaping MicropubSessionResolver.Factory = MicropubSessionResolver.defaultFactory()) {
        self.makeMicropubClient = makeMicropubClient
    }

    /// Whether this site has a resolvable Micropub session right now — gates the composer's
    /// "Restricted" visibility option (design §5.1).
    func isAvailable(siteID: String, sourceDirectory: URL) async -> Bool {
        await makeMicropubClient(siteID, sourceDirectory) != nil
    }

    /// Creates a restricted post directly via Micropub — never touches `Source/` or git.
    func createPost(title: String, body: String, siteID: String, sourceDirectory: URL) async -> ComposerCreateOutcome {
        guard let client = await makeMicropubClient(siteID, sourceDirectory) else {
            return .failed(reason: "This site isn't connected for restricted posts. Connect it from Website ▸ Connect Site first.")
        }
        let post = MicropubPost.entry(title: title, content: body, status: .published, visibility: .contacts)
        do {
            _ = try await client.create(post)
            return .success
        } catch let error as MicropubError where error.requiresReauthorization {
            return .failed(reason: "Sign in again to publish restricted posts on this site.")
        } catch let error as MicropubError {
            return .failed(reason: "Publish failed: \(Self.describe(error))")
        } catch {
            return .failed(reason: "Publish failed. Please try again.")
        }
    }

    /// A site owner-facing sentence for each `MicropubError` case. `MicropubError` is a plain
    /// `Error` with no `LocalizedError` conformance, so `localizedDescription` renders the raw
    /// Swift type dump ("The operation couldn't be completed. (AnglesiteCore.MicropubError error
    /// 3.)") — never a string to show someone publishing a post.
    ///
    /// Deliberately a local mirror of `PostComposerModel`'s own private `describe(_:)` rather than
    /// a new exported helper in `AnglesiteCore`: this feature keeps its sharing *within* a module
    /// (that's what `MicropubSessionResolver` does for the Mac's session resolution) and accepts a
    /// handful of duplicated lines across the Mac/iOS boundary, so each surface stays free to word
    /// its copy for its own context.
    private static func describe(_ error: MicropubError) -> String {
        switch error {
        case .requestFailed(let status, _):
            return "The site declined the request (HTTP \(status))."
        case .decodingFailed:
            return "The site's response wasn't understood."
        case .mediaEndpointNotConfigured:
            return "This site has no media endpoint configured."
        case .dpopUnavailable:
            return "Secure signing is unavailable on this device."
        case .serverError(let status, _):
            return "The site's server had trouble (HTTP \(status)). Try again in a moment."
        case .unreachable:
            return "The site couldn't be reached. Check your connection and try again."
        case .unauthorized:
            // Routed to the re-auth arm above before reaching here; text kept for completeness.
            return "The request wasn't authorized."
        }
    }
}
