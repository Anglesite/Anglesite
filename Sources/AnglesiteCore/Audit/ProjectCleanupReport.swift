import Foundation

/// Merges `DeadAssetScanner`'s unused-component/layout/image candidates with
/// `LinkGraph.orphanPages` (already computed elsewhere, only ever surfaced per-page in the
/// Related Pages panel until now) into one sorted list for the Navigator's Cleanup section.
public enum ProjectCleanupReport {
    /// `orphanPages` always has zero inbound links by definition, so `referenceCount` is
    /// hardcoded to 0 for every page candidate — not a placeholder, an accurate reflection of
    /// what "orphan" means.
    public static func build(
        deadAssets: [DeadAssetScanner.CleanupCandidate],
        orphanPages: [SiteKnowledgeIndex.Document]
    ) -> [DeadAssetScanner.CleanupCandidate] {
        let pageCandidates = orphanPages.map { doc in
            DeadAssetScanner.CleanupCandidate(
                id: doc.path, path: doc.path, kind: .page,
                lastModified: doc.lastModified, referenceCount: 0)
        }
        return (deadAssets + pageCandidates).sorted { $0.path < $1.path }
    }
}
