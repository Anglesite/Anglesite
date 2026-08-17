import Foundation

/// Watches a boot's guest output for an npm dependency-resolution failure (#1440 part 1).
///
/// The post-apply preview boot's `npm ci`/`npm install` (hydrate) is the install verification
/// for an accepted dependency update — but it runs as a detached guest process, so its failure
/// only surfaces minutes later as a generic serving timeout. This scanner keeps the
/// resolution-failure evidence from the output stream so the settled failure can name the
/// actual problem in owner terms (consequences to the site, not npm mechanics — the raw npm
/// output stays in the debug log per "logs are sacred").
///
/// Thread-safe (`ingest` is called from the container's `@Sendable` output callback while
/// `diagnosis` is read from the runtime actor); `@unchecked` because the lock, not the
/// compiler, guards the mutable state.
public final class DependencyInstallFailureScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var sawResolutionFailure = false
    private var conflict: (peerName: String, dependentName: String)?

    /// Matches npm's ERESOLVE detail line, e.g.
    /// `npm error peer astro@"^6.3.0" from @astrojs/cloudflare@13.5.0` — capturing the
    /// peer package name and the dependent that requires it (non-greedy so scoped names
    /// keep their leading `@`).
    private static let peerConflictRegex = try? NSRegularExpression(
        pattern: #"peer\s+(\S+?)@"[^"]*"\s+from\s+(\S+?)@[0-9]"#)

    public init() {}

    /// Feed one line of guest boot output.
    ///
    /// - Parameter line: A single stdout/stderr line from the container's boot stream.
    public func ingest(line: String) {
        let isFailureMarker = line.contains("ERESOLVE") || line.contains("Could not resolve dependency")
        var parsedConflict: (String, String)?
        if let regex = Self.peerConflictRegex,
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
           let peerRange = Range(match.range(at: 1), in: line),
           let dependentRange = Range(match.range(at: 2), in: line) {
            parsedConflict = (String(line[peerRange]), String(line[dependentRange]))
        }
        guard isFailureMarker || parsedConflict != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        if isFailureMarker { sawResolutionFailure = true }
        if conflict == nil, let (peer, dependent) = parsedConflict {
            conflict = (peerName: peer, dependentName: dependent)
        }
    }

    /// An owner-phrased explanation of the install failure, or `nil` when no
    /// resolution-failure evidence has been seen.
    public var diagnosis: String? {
        lock.lock()
        defer { lock.unlock() }
        guard sawResolutionFailure else { return nil }
        if let conflict {
            return "The site's pieces stopped fitting together: \(conflict.dependentName) needs a "
                + "different version of \(conflict.peerName) than the site now has, so the site's "
                + "packages couldn't be installed and the preview can't start. The full details "
                + "are in the debug log."
        }
        return "The site's pieces stopped fitting together — two things this site depends on "
            + "need different versions of the same package, so the site's packages couldn't be "
            + "installed and the preview can't start. The full details are in the debug log."
    }
}
