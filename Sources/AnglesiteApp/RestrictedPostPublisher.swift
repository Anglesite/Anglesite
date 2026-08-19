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
        } catch {
            return .failed(reason: "Publish failed: \(error.localizedDescription)")
        }
    }
}
