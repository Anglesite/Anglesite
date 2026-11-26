import Foundation

/// Where the complete source code of the running build is published (#2231).
///
/// The app statically links LGPL-2.1+ code (libgit2's bundled LibXDiff, via SwiftGit2), which
/// LGPL-2.1 §6 allows when recipients can rebuild the app against a modified copy of that
/// library. Anglesite meets that by publishing all of its source: the Acknowledgments window
/// points at the exact revision a build was made from, so the corresponding source is one click
/// away. `scripts/release.sh` stamps that revision into the app's `Info.plist`
/// (``infoPlistKey``) when it archives a release from a clean, published checkout; any other
/// build leaves it empty and points at the repository instead.
public struct AppSourceCode: Sendable, Equatable {
    /// The public repository the app is built from.
    public static let repositoryURL = URL(string: "https://github.com/Anglesite/Anglesite")!

    /// The `Info.plist` key `scripts/release.sh` stamps the build's full revision into, via the
    /// `ANGLESITE_SOURCE_REVISION` build setting.
    public static let infoPlistKey = "AnglesiteSourceRevision"

    /// The full revision (lowercase hex) this build was made from, or `nil` when the build
    /// wasn't stamped, for example a local Debug build.
    public let revision: String?

    /// Creates a value from a stamped revision, keeping it only if it looks like a full revision
    /// id: 40 or 64 hex digits (SHA-1 or SHA-256 object names). Anything else, including the empty
    /// string an unstamped build carries, becomes `nil`, so a malformed value can never produce a
    /// link to a path that doesn't exist.
    public init(revision: String?) {
        let trimmed = revision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isHex = !trimmed.isEmpty && trimmed.allSatisfy { $0.isHexDigit }
        self.revision = isHex && (trimmed.count == 40 || trimmed.count == 64) ? trimmed : nil
    }

    /// Reads the stamped revision from a bundle's `Info.plist` contents.
    public init(infoDictionary: [String: Any]?) {
        self.init(revision: infoDictionary?[Self.infoPlistKey] as? String)
    }

    /// The source of the app that is running now.
    public static var current: AppSourceCode {
        AppSourceCode(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Whether ``url`` points at this build's exact source rather than the repository's front
    /// page.
    public var isExactBuild: Bool { revision != nil }

    /// The source browser for ``revision`` when the build was stamped, otherwise the repository.
    public var url: URL {
        guard let revision else { return Self.repositoryURL }
        return Self.repositoryURL.appendingPathComponent("tree").appendingPathComponent(revision)
    }
}
