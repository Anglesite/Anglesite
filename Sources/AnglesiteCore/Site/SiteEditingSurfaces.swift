import AnglesiteSiteModel
import Foundation

/// Which of the app's editing surfaces a site offers, decided by its site kind (#2050,
/// decision 6 in `docs/specs/2026-09-28-external-cms-content-source-decision.md`).
///
/// On an EmDash site, EmDash is canonical for articles and media, so the app hides its
/// typed-content editors (New Post, New Link Post, collection entries, the typed inspector form,
/// Publish/Move to Drafts) and offers "Open EmDash" instead. The block editor stays the owner's
/// surface for what git still holds: pages, layout and theme. A kind this build doesn't recognise
/// opens read-only (`AnglesitePackage.compatibility(for:)`), so it offers nothing.
///
/// Pure and I/O-free, like ``CMSModeStatus``: the app reads it synchronously from
/// `SiteStore.Site.kind` for `.disabled(...)` gates, and the create paths call
/// ``requireTypedContent()`` as a backstop so Shortcuts, AppleScript, drag-and-drop and paste
/// can't write typed content into an EmDash site's `Source/` either. Copy-free: the app owns the
/// owner-facing sentences.
public struct SiteEditingSurfaces: Sendable, Equatable {
    /// Where authored content is edited when it isn't edited in the app.
    public enum ExternalContentEditor: Sendable, Equatable {
        case emdash
    }

    /// Thrown by ``requireTypedContent()`` when a typed-content write targets a site whose
    /// content lives elsewhere.
    public struct TypedContentUnavailable: Error, Sendable, Equatable {
        public let kind: AnglesitePackage.SiteKind
        /// Where the owner should go instead, if anywhere.
        public let externalContentEditor: ExternalContentEditor?
    }

    public let kind: AnglesitePackage.SiteKind
    /// New Post / New Link Post / collection entries, the typed inspector form, Publish Post and
    /// Move to Drafts.
    public let typedContent: Bool
    /// Pages, layout, components and theme (the block editor, decision D4).
    public let pagesAndLayout: Bool
    /// The editor that owns this site's content, when it isn't the app.
    public let externalContentEditor: ExternalContentEditor?
    /// Whether Publish Site may run the built-in static deploy (build `dist/`, scan, `wrangler
    /// deploy`). `false` on an EmDash site: it is server-rendered (decision 4), so a static build
    /// would publish a site with none of its articles over the real one. `DeployCommand` refuses a
    /// static target for it with ``staticDeployUnavailableReason``.
    public let staticDeploy: Bool
    /// Whether Publish Site deploys this site as a server-rendered EmDash Worker (decision 7,
    /// #2103): `EmDashDeployTarget`. `true` only on an EmDash site.
    public let serverRenderedDeploy: Bool

    public init(kind: AnglesitePackage.SiteKind) {
        self.kind = kind
        switch kind {
        case .anglesite:
            typedContent = true
            pagesAndLayout = true
            externalContentEditor = nil
            staticDeploy = true
            serverRenderedDeploy = false
        case .emdash:
            typedContent = false
            pagesAndLayout = true
            externalContentEditor = .emdash
            staticDeploy = false
            serverRenderedDeploy = true
        case .unrecognized:
            typedContent = false
            pagesAndLayout = false
            externalContentEditor = nil
            staticDeploy = false
            serverRenderedDeploy = false
        }
    }

    /// Throws ``TypedContentUnavailable`` unless this site edits typed content in the app.
    public func requireTypedContent() throws {
        guard typedContent else {
            throw TypedContentUnavailable(kind: kind, externalContentEditor: externalContentEditor)
        }
    }

    /// The surfaces for the site whose `Source/` is `sourceDirectory`, read from the enclosing
    /// package's marker.
    ///
    /// - A directory that isn't a package's `Source/` at all (tests, the import path) is an
    ///   Anglesite site, as it always has been.
    /// - A package's `Source/` whose marker can't be read right now (iCloud eviction, a lost
    ///   security scope) gets `unreadableMarkerFallback` — a site window passes its recents
    ///   entry's kind — and otherwise **fails closed** as an unrecognised kind, so the
    ///   ``ContentCreationWorkflow`` backstop never lets a typed write into an EmDash site through
    ///   on a transient read error.
    public static func forSourceDirectory(
        _ sourceDirectory: URL,
        unreadableMarkerFallback: AnglesitePackage.SiteKind? = nil,
        fileManager: FileManager = .default
    ) -> SiteEditingSurfaces {
        let packageURL = sourceDirectory.standardizedFileURL.deletingLastPathComponent()
        let package = AnglesitePackage(url: packageURL)
        guard packageURL.pathExtension == AnglesitePackage.packageExtension,
              package.sourceURL.standardizedFileURL == sourceDirectory.standardizedFileURL
        else { return SiteEditingSurfaces(kind: .anglesite) }
        guard let marker = try? package.readMarker(fileManager: fileManager) else {
            return SiteEditingSurfaces(kind: unreadableMarkerFallback ?? .unrecognized(unreadableMarkerKind))
        }
        return SiteEditingSurfaces(kind: marker.kind)
    }

    /// The placeholder kind ``forSourceDirectory(_:unreadableMarkerFallback:fileManager:)``
    /// reports when a package's marker can't be read.
    static let unreadableMarkerKind = "unreadable-marker"

    /// The `.failed(reason:)` text ``ContentCreationWorkflow`` returns when a typed-content write
    /// targets an EmDash site, surfaced verbatim by Shortcuts and AppleScript dialogs. Phrased
    /// about the site, never about files or git (decision D1).
    public static let typedContentUnavailableReason =
        "This site's posts are written and published in EmDash, not in Anglesite. Open EmDash to add or publish a post."

    /// Why Publish Site can't run at all for the site whose `Source/` is `sourceDirectory`, or
    /// `nil` when it can: the app's Publish Site gate. An Anglesite site publishes statically and
    /// an EmDash site as its EmDash Worker (#2103); a package whose marker can't be read, or names
    /// a kind this build doesn't know, fails closed (no recents fallback) with
    /// ``siteKindUnconfirmedReason``. `DeployCommand` then refuses a target that doesn't match the
    /// kind (``deployRefusal(sourceDirectory:serverRendered:fileManager:)``).
    public static func publishRefusal(sourceDirectory: URL, fileManager: FileManager = .default) -> String? {
        let surfaces = forSourceDirectory(sourceDirectory, fileManager: fileManager)
        return surfaces.staticDeploy || surfaces.serverRenderedDeploy ? nil : siteKindUnconfirmedReason
    }

    /// Why `DeployCommand` can't publish the site whose `Source/` is `sourceDirectory` through a
    /// target that renders on the server (`serverRendered`) or not, or `nil` when it can. An
    /// EmDash site needs a server-rendered target and gets ``staticDeployUnavailableReason`` from
    /// any other; an Anglesite site gets ``serverRenderedDeployUnavailableReason`` from a
    /// server-rendered one; an unreadable or unknown kind gets ``siteKindUnconfirmedReason``.
    public static func deployRefusal(
        sourceDirectory: URL, serverRendered: Bool, fileManager: FileManager = .default
    ) -> String? {
        let surfaces = forSourceDirectory(sourceDirectory, fileManager: fileManager)
        if serverRendered ? surfaces.serverRenderedDeploy : surfaces.staticDeploy { return nil }
        switch surfaces.kind {
        case .emdash: return staticDeployUnavailableReason
        case .anglesite: return serverRenderedDeployUnavailableReason
        case .unrecognized: return siteKindUnconfirmedReason
        }
    }

    /// ``deployRefusal(sourceDirectory:serverRendered:fileManager:)`` for a static target.
    public static func staticDeployRefusal(sourceDirectory: URL, fileManager: FileManager = .default) -> String? {
        deployRefusal(sourceDirectory: sourceDirectory, serverRendered: false, fileManager: fileManager)
    }

    /// The `.failed(reason:)` text `DeployCommand` returns when an EmDash site reaches a static
    /// deploy target. Phrased about the site (decision D1).
    public static let staticDeployUnavailableReason =
        "This site's articles are published from EmDash, so it can't be published as a static copy without them. Nothing was published."

    /// The `.failed(reason:)` text `DeployCommand` returns when a site that isn't an EmDash site
    /// reaches the EmDash deploy.
    public static let serverRenderedDeployUnavailableReason =
        "This site doesn't publish its articles from EmDash, so it can't be published as an EmDash site. Nothing was published."

    /// The `.failed(reason:)` text `DeployCommand` returns when it can't confirm what kind of site
    /// it's publishing (the package's marker couldn't be read, or names a kind this build doesn't
    /// know). Nothing is published.
    public static let siteKindUnconfirmedReason =
        "Anglesite couldn't confirm what kind of website this is, so nothing was published. Try again once the website's files are available on this Mac."

    /// The EmDash admin to open for this site: `settings.emdashAdminURL` when this is an EmDash
    /// site and the URL is `https` with a host. Anything else (not yet provisioned or connected, a
    /// non-EmDash site, or a non-web URL a hand-edited `settings.plist` could carry) is `nil`, so
    /// "Open EmDash" never hands `NSWorkspace` a `file:` or custom-scheme URL.
    public func emdashAdminURL(settings: SiteSettings) -> URL? {
        guard externalContentEditor == .emdash,
              let url = settings.emdashAdminURL,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
