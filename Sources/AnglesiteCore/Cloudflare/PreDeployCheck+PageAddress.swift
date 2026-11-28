import Foundation

extension PreDeployCheck {
    /// The address a visitor would type for the built page a scan finding points at, or `nil`
    /// when the finding isn't on a page (a stylesheet, script, `_headers`, a source file).
    ///
    /// The blocked-publish sheet leads with this instead of the raw output path, so the owner
    /// reads "On /contact/" rather than `dist/contact/index.html` (#2211, decision D1) — the raw
    /// path still goes under the sheet's Details disclosure. `file` is the scan's
    /// `Source/`-relative path; only built pages under `dist/` map to an address.
    ///
    /// - `dist/index.html` → `/`
    /// - `dist/contact/index.html` → `/contact/`
    /// - `dist/404.html` → `/404`
    public static func pageAddress(forPublishedFile file: String) -> String? {
        var path = file.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard path.hasPrefix("dist/"), path.lowercased().hasSuffix(".html") else { return nil }
        path.removeFirst("dist/".count)
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }

        let lowered = path.lowercased()
        if lowered == "index.html" { return "/" }
        if lowered.hasSuffix("/index.html") {
            return "/" + path.dropLast("index.html".count)
        }
        return "/" + path.dropLast(".html".count)
    }
}
