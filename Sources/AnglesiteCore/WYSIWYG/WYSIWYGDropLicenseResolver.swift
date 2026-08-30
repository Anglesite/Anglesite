import Foundation

/// Resolves the ``LicenseRef`` (if any) a WYSIWYG-canvas image drop should embed, mirroring
/// `Insert ▸ Image…`'s persisted choice without a picker (#1671, split from #999 §4: "drop and
/// inspect").
///
/// A drag is a direct-manipulation gesture a modal would derail, so a drop never shows a picker —
/// it applies only the persisted `AppSettings.lastUsedFileLicenseSelection`. No selection, or a
/// disabled one, resolves to `nil` rather than falling back to the collection's resolved default
/// license (unlike `InsertImageLicenseChoice.initial`'s no-`lastUsed` branch): embedding is a
/// destructive edit, and a drop must never be the path that silently starts writing metadata.
public enum WYSIWYGDropLicenseResolver {
    /// - Parameters:
    ///   - policy: The site's loaded content-licensing policy.
    ///   - route: The active page route the drop landed on, e.g. `preview.activeRoute ?? "/"`.
    ///   - lastUsed: `AppSettings.shared.lastUsedFileLicenseSelection` — the choice last made
    ///     through `Insert ▸ Image…`'s accessory picker.
    /// - Returns: The license to embed, or `nil` when the collection suppresses per-file
    ///   embedding, no selection has been persisted, the persisted one is disabled, or its
    ///   `catalogID` no longer names a ``LicenseCatalog`` entry.
    public static func resolve(
        policy: LicensingPolicy, route: String, lastUsed: FileLicenseSelection?
    ) -> LicenseRef? {
        let collection = LicensableCollection(routePath: route)
        guard !policy.suppressesFileEmbedding(for: collection) else { return nil }
        guard let lastUsed, lastUsed.isEnabled else { return nil }
        return LicenseCatalog.entries.first { $0.id == lastUsed.catalogID }?.ref
    }
}
