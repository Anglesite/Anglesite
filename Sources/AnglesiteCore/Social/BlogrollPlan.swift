import Foundation

/// Network-free planning for blogroll entries: enumerates `src/content/blogroll/` (only —
/// unlike ``StandardSiteDocumentPlan``, this never walks the whole content tree, since blogroll
/// entries are not documents; see that type's exclusion of this same collection).
public enum BlogrollPlan {
    /// One blogroll entry ready for graph-record resolution.
    public struct Entry: Equatable, Sendable {
        /// Project-relative POSIX path of the source markdown file.
        public let sourceFile: String
        public let name: String
        public let url: URL
        /// Already-set `feedURL` frontmatter, if the owner supplied one or a prior deploy's
        /// discovery pass wrote one back. `nil` means discovery should still be attempted.
        public let feedURL: URL?

        public init(sourceFile: String, name: String, url: URL, feedURL: URL?) {
            self.sourceFile = sourceFile
            self.name = name
            self.url = url
            self.feedURL = feedURL
        }
    }

    public struct Plan: Equatable, Sendable {
        public let entries: [Entry]
        public init(entries: [Entry]) { self.entries = entries }
    }

    /// Builds the blogroll plan for a site's Astro project root (`Source/`).
    public static func build(projectRoot: URL) -> Plan {
        let blogrollRoot = projectRoot.appendingPathComponent("src/content/blogroll", isDirectory: true)
        let files = SocialPublishPlan.walk(blogrollRoot)
            .filter { SocialPublishPlan.entryExtensions.contains($0.pathExtension.lowercased()) }
        let entries = files.compactMap { file -> Entry? in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let frontmatter = Frontmatter.parse(source)
            guard let name = SocialPublishPlan.string(frontmatter["name"]), !name.isEmpty else { return nil }
            guard let urlString = SocialPublishPlan.string(frontmatter["url"]), let url = URL(string: urlString) else {
                return nil
            }
            let feedURL = SocialPublishPlan.string(frontmatter["feedURL"]).flatMap(URL.init(string:))
            let relPath = SocialPublishPlan.relativePosix(file, from: projectRoot)
            return Entry(sourceFile: relPath, name: name, url: url, feedURL: feedURL)
        }
        return Plan(entries: entries.sorted { $0.sourceFile < $1.sourceFile })
    }
}
