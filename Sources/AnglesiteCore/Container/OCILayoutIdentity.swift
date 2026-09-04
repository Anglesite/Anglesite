import Foundation

/// Byte-identity checks for OCI layouts, shared by `OCILayoutStaging` (staged copy vs bundled
/// source) and `OCILayoutImportMarker` (recorded import vs current layout) so the two can't drift.
///
/// In an OCI layout `index.json` carries the manifest digests, so any change to the image changes
/// it — byte-comparing it is an image-identity check without hashing the blobs. Unreadable inputs
/// compare as non-matching, so every consumer fails toward re-staging/re-importing (cheap and
/// correct) rather than trusting stale state.
public enum OCILayoutIdentity {
    /// The identity-bearing file of an OCI layout.
    public static func indexURL(of layout: URL) -> URL {
        layout.appendingPathComponent("index.json")
    }

    /// True when both files exist and byte-match; false otherwise.
    public static func contentsMatch(_ a: URL, _ b: URL) -> Bool {
        guard
            let aData = try? Data(contentsOf: a),
            let bData = try? Data(contentsOf: b)
        else { return false }
        return aData == bData
    }
}
