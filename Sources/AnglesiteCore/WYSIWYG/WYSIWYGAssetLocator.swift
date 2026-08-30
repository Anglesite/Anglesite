import Foundation

/// Resolves a WYSIWYG image block's `src` prop back to the on-disk file
/// `WYSIWYGImageAssetIngestor` wrote it to, so the license inspector (#1672) can read and
/// rewrite the exact same bytes. Read-only: this type never touches the filesystem itself, only
/// computes a path — callers decide what to do with it (check existence, read, write).
public enum WYSIWYGAssetLocator {
    /// `src` → the file URL under `<siteDirectory>/public/` it names, or `nil` when `src` isn't a
    /// root-relative path into that directory: an absolute URL (`http(s)://…`), a protocol-
    /// relative URL (`//host/…`), a `data:` URL, a bare relative path, or anything that resolves
    /// (via `..`) outside `public/` are all `nil` rather than a guessed location. Does not check
    /// that the file actually exists — that's a separate, cheaper check callers make themselves.
    public static func resolve(src: String, siteDirectory: URL) -> URL? {
        guard src.hasPrefix("/"), !src.hasPrefix("//") else { return nil }
        let relativePath = String(src.dropFirst())
        guard !relativePath.isEmpty else { return nil }

        let publicDirectory = siteDirectory.appendingPathComponent("public", isDirectory: true).standardizedFileURL
        let candidate = publicDirectory.appendingPathComponent(relativePath).standardizedFileURL
        let publicPathWithSlash = publicDirectory.path.hasSuffix("/") ? publicDirectory.path : publicDirectory.path + "/"
        guard candidate.path.hasPrefix(publicPathWithSlash) else { return nil }
        return candidate
    }
}
