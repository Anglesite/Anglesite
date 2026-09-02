import Foundation

/// The one place a site's identity (display name, `.site-config` fallback, or a stock UUID site
/// id) is turned into a Worker name that wrangler will actually accept — shared by the deploy
/// path (`DeployCoordinator.resolveWorkerSiteName`, `SiteOperations`, `SiteScaffolder`) and the
/// local wrangler-dev path (`ContainerizationControl.startWorkersDev`) so the two can't drift
/// again (#1750).
///
/// Before this existed, the local-dev path passed the raw site UUID straight into
/// `WorkerComposition.generateWranglerToml`. That satisfied the generator's own `[A-Za-z0-9_-]+`
/// check but not wrangler's: `name` must be *lowercase*, and every R2 `bucket_name` derived from
/// it (`<name>-media`, `<name>-pod-blobs`) must be lowercase too — so `wrangler dev` refused the
/// config on every attempt and the Debug Pane row crash-looped to **Failed** on every
/// UUID-identified site (i.e. every site). The deploy path never hit it only because it happened
/// to go through `SiteSlug.derive` first.
public enum WorkerSiteName {
    /// The longest resource-name suffix `WorkerComposition.generateWranglerToml` appends to a site
    /// name (`-webmention`, the default `[[queues]]` name). ``maxLength`` is budgeted against it so
    /// *every* derived resource name stays within Cloudflare's 63-character R2 bucket-name limit
    /// (queue and D1 names allow at least as much). Update this if composition ever gains a
    /// longer suffix — `WorkerSiteNameTests` pins the current set.
    static let longestResourceSuffix = "-webmention"

    /// Cloudflare's upper bound on an R2 bucket name, the tightest of the derived-resource limits.
    static let maxResourceNameLength = 63

    /// The longest site name ``derive(from:)`` will return: 63 minus ``longestResourceSuffix``.
    public static let maxLength = maxResourceNameLength - longestResourceSuffix.count

    /// Derives a wrangler-valid Worker name from any raw site identity.
    ///
    /// Runs `raw` through `SiteSlug.derive` (lowercase ASCII alphanumerics and single hyphens,
    /// diacritics folded, `untitled-site` when nothing survives) and then caps the result at
    /// ``maxLength`` without leaving a trailing hyphen. The output is deterministic for a given
    /// input — a site id always maps to the same name, so a restarted local wrangler-dev session
    /// re-opens the same Miniflare-persisted state — and a lowercased UUID keeps the per-site
    /// uniqueness the raw UUID had.
    ///
    /// - Parameter raw: A display name, an existing slug, or a site UUID. An already-valid slug
    ///   short enough to fit the budget passes through unchanged.
    /// - Returns: A name that satisfies ``isValidWorkerName(_:)`` and whose every
    ///   `WorkerComposition`-derived resource name satisfies ``isValidR2BucketName(_:)``.
    public static func derive(from raw: String) -> String {
        var slug = SiteSlug.derive(from: raw)
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        // SiteSlug never returns empty and the cut can only shorten a non-empty alphanumeric
        // run, but keep the same fallback it uses so the contract holds regardless.
        return slug.isEmpty ? "untitled-site" : slug
    }

    /// Whether `name` satisfies wrangler's rule for the top-level `name` field — "alphanumeric
    /// and lowercase with dashes only": `^[a-z0-9_][a-z0-9_-]*$` (wrangler's own regex minus the
    /// space it tolerates, which would poison every derived resource name).
    public static func isValidWorkerName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9_][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    /// Whether `name` satisfies wrangler's rule for an R2 `bucket_name`: lowercase letters,
    /// digits, and hyphens only; 3–63 characters; begins and ends with an alphanumeric.
    public static func isValidR2BucketName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil
    }
}
