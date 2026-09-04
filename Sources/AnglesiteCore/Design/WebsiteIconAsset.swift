import Foundation

/// Deterministic website icon links and metadata for an Anglesite site's public assets.
public enum WebsiteIconAsset {
    /// Astro's static-assets directory, where all icon files land (served from the site root).
    public static let publicDirectoryRelativePath = "public"
    /// The template's base layout — the one `<head>` every page shares, so patching it once
    /// covers the whole site.
    public static let layoutRelativePath = "src/layouts/BaseLayout.astro"
    /// Legacy-format favicon, still the widest-compatibility fallback (`sizes="any"`).
    public static let faviconICOName = "favicon.ico"
    /// PNG favicon for browsers that prefer it over ICO.
    public static let faviconPNGName = "favicon.png"
    /// Home-screen icon for iOS/iPadOS Safari.
    public static let appleTouchIconName = "apple-touch-icon.png"
    /// PWA manifest icon at 192×192 — the minimum Android install-prompt size.
    public static let icon192Name = "icon-192.png"
    /// PWA manifest icon at 512×512 — used for splash screens and high-density launchers.
    public static let icon512Name = "icon-512.png"
    /// The web-app manifest filename referenced from ``headLinks``.
    public static let manifestName = "site.webmanifest"

    /// Failures ``WebsiteIconAsset/patchLayout(in:fileManager:)`` can throw.
    public enum InstallError: Error, Sendable {
        /// The base layout file doesn't exist where the template puts it.
        case layoutNotFound(URL)
    }

    /// Every `<link>` ``insertHeadLinks(into:)`` can add, each paired with the href that marks it
    /// already present. Some entries (e.g. `favicon.ico`) may already be baked into a site's
    /// layout by the template itself, independent of a custom icon install — so each line's
    /// presence is checked on its own rather than treating the set as all-or-nothing.
    static let headLinkEntries: [(href: String, line: String)] = [
        (#"href="/favicon.ico""#, #"<link rel="icon" href="/favicon.ico" sizes="any" />"#),
        (#"href="/favicon.png""#, #"<link rel="icon" type="image/png" href="/favicon.png" />"#),
        (#"href="/apple-touch-icon.png""#, #"<link rel="apple-touch-icon" href="/apple-touch-icon.png" />"#),
        (#"href="/site.webmanifest""#, #"<link rel="manifest" href="/site.webmanifest" />"#)
    ]

    /// The exact `<link>` block inserted after `<head>` when none of `headLinkEntries` are
    /// present yet — derived from that array so the two can't drift out of sync.
    public static let headLinks = headLinkEntries.map(\.line).joined(separator: "\n")

    /// Inserts whichever `headLinkEntries` lines are missing right after `<head>`, idempotently:
    /// a line whose href already appears anywhere in the source (from a prior install, the
    /// template baseline, or hand-authoring) is left alone rather than duplicated. Pure — the
    /// file write lives in ``patchLayout(in:fileManager:)``.
    public static func insertHeadLinks(into source: String) -> String {
        let missingLines = headLinkEntries.filter { !source.contains($0.href) }.map(\.line)
        guard !missingLines.isEmpty, let headRange = source.range(of: "<head>") else { return source }
        let insertion = "\n" + missingLines.joined(separator: "\n")
        var patched = source
        patched.insert(contentsOf: insertion, at: headRange.upperBound)
        return patched
    }

    /// Applies ``insertHeadLinks(into:)`` to the site's base layout on disk, writing only when
    /// the insertion actually changed something (no spurious mtime churn / git noise).
    public static func patchLayout(in siteDirectory: URL, fileManager: FileManager = .default) throws {
        let layoutURL = siteDirectory.appendingPathComponent(layoutRelativePath)
        guard fileManager.fileExists(atPath: layoutURL.path) else {
            throw InstallError.layoutNotFound(layoutURL)
        }
        let source = try String(contentsOf: layoutURL, encoding: .utf8)
        let patched = insertHeadLinks(into: source)
        if patched != source {
            try patched.write(to: layoutURL, atomically: true, encoding: .utf8)
        }
    }

    /// Renders the `site.webmanifest` JSON for the two PWA icons. Sorted keys keep the output
    /// byte-stable across runs, so re-installing icons doesn't dirty the site's git repo.
    public static func manifestData(siteName: String) throws -> Data {
        let manifest: [String: Any] = [
            "name": siteName,
            "short_name": siteName,
            "icons": [
                [
                    "src": "/icon-192.png",
                    "sizes": "192x192",
                    "type": "image/png"
                ],
                [
                    "src": "/icon-512.png",
                    "sizes": "512x512",
                    "type": "image/png"
                ]
            ],
            "display": "standalone"
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    /// Every file the icon install writes into `public/`, whether or not it exists yet — the
    /// single list uninstall/inspection logic should iterate instead of re-deriving filenames.
    public static func installedIconURLs(in siteDirectory: URL) -> [URL] {
        let publicDir = siteDirectory.appendingPathComponent(publicDirectoryRelativePath, isDirectory: true)
        return [
            faviconICOName,
            faviconPNGName,
            appleTouchIconName,
            icon192Name,
            icon512Name,
            manifestName
        ].map { publicDir.appendingPathComponent($0) }
    }

    /// True when the site owner has actually gone through Website Icon install — checked via
    /// the PWA-only artifacts (192/512 manifest icons, `site.webmanifest`), never the favicon
    /// trio. The template ships a generic favicon.ico/favicon.png/apple-touch-icon.png with every
    /// scaffolded site (#1525), so their mere presence no longer means "installed"; the
    /// PWA-manifest files are still written only by `WebsiteIconInstaller.install` (AnglesiteApp),
    /// so they're an accurate signal for the Settings ▸ Website Icon "Installed" state.
    public static func hasInstalledIcons(in siteDirectory: URL, fileManager: FileManager = .default) -> Bool {
        let publicDir = siteDirectory.appendingPathComponent(publicDirectoryRelativePath, isDirectory: true)
        return [icon192Name, icon512Name, manifestName]
            .map { publicDir.appendingPathComponent($0) }
            .contains { fileManager.fileExists(atPath: $0.path) }
    }
}
