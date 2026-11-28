import Foundation

/// Carries changes made to a site's host `Source/` outside Anglesite (VS Code, a terminal, a
/// `git pull`) into the running container's working copy, so the open preview shows them (#2242).
///
/// The preview runs from the guest's own clone (`/workspace/site`). Before this, the only path
/// from host to guest was `LocalContainerSiteRuntime.syncFromHost()`'s `git pull --ff-only`: it
/// carried committed changes only, and ran only after the app's own content operations. And the
/// guest can't read the host's working tree directly: in the split-repo layout (#888) its
/// read-only share is just the git directory.
///
/// One batch from the host watcher becomes:
/// 1. a **probe** (one guest `exec`) reporting, per changed path, the guest file's hash and the
///    hash of the guest's committed version, plus whether the guest has commits the host doesn't;
/// 2. a **plan**: copy a host file into the guest only when the guest's copy is untouched, i.e. it
///    still matches the guest's `HEAD`, or is exactly what this sync last wrote there. A guest
///    copy changed some other way (an edit in progress inside the guest) is kept, and the batch
///    reports a conflict. If the guest has commits the host lacks (editor work not yet saved back),
///    nothing is copied at all;
/// 3. **writes** (one `exec` per file, content as base64 in argv chunks, written to a temp file and
///    renamed into place) and deletes.
///
/// It never touches `.git` or generated/dependency directories (`SiteIndexPaths`), never merges,
/// and never asks the owner about git: an unsafe copy is simply skipped and logged.
public enum HostSourceSync {
    /// The probe's verdict for one path, as the guest sees it.
    public struct GuestFileState: Equatable, Sendable {
        public var path: String
        /// SHA-256 (hex) of the guest's working-tree file, or `nil` if it doesn't exist.
        public var current: String?
        /// SHA-256 (hex) of the file as committed at the guest's `HEAD`, or `nil` if not committed.
        public var committed: String?

        public init(path: String, current: String?, committed: String?) {
            self.path = path
            self.current = current
            self.committed = committed
        }
    }

    /// What one sync decided for one path.
    public enum Action: Equatable, Sendable {
        /// Write the host's bytes to the guest. `sha256` is their hash, recorded once written.
        case write(path: String, sha256: String)
        /// Remove the guest's file; the host deleted it.
        case delete(path: String)
        /// The guest already has exactly this.
        case unchanged(path: String)
        /// The guest's copy changed since the last sync or commit, so it's kept.
        case conflict(path: String)
        /// Too large to carry this way.
        case tooLarge(path: String)
    }

    /// Files bigger than this aren't carried (base64 in argv chunks gets slow well before this).
    public static let maxFileBytes = 16 * 1024 * 1024

    /// Base64 characters per `exec` argument: under Linux's 128 KiB `MAX_ARG_STRLEN`.
    static let chunkCharacters = 96 * 1024

    /// The guest working copy every script runs in.
    public static let guestWorkingDirectory = "/workspace/site"

    // MARK: - Paths

    /// The site-relative paths in `batch` worth carrying, sorted and de-duplicated. `nil` when the
    /// watcher lost per-file detail (`needsFullRescan`), which this doesn't try to reconstruct.
    public static func relevantPaths(in batch: FileChangeBatch, sourceDirectory: URL) -> [String]? {
        guard !batch.needsFullRescan else { return nil }
        var paths = Set<String>()
        for url in batch.paths {
            guard let relative = SiteIndexPaths.relativePOSIXPath(of: url, under: sourceDirectory),
                  isCarried(relative)
            else { continue }
            paths.insert(relative)
        }
        return paths.sorted()
    }

    /// Never `.git` (in any form) or a skipped generated/dependency directory, and never a path
    /// that could escape the working copy.
    static func isCarried(_ relative: String) -> Bool {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if components.contains(".git") { return false }
        return !SiteIndexPaths.isSkipped(relativePath: relative)
    }

    // MARK: - Probe

    /// `argv` for the probe. Prints one header line, `ahead <n> behind <m>` — the guest's commits
    /// not on the host's branch (`origin`, the read-only host share) and the host's commits not in
    /// the guest — then one line per path: `<current sha|->\t<committed sha|->\t<path>`.
    public static func probeArgv(paths: [String]) -> [String] {
        let script = """
        git fetch -q origin 2>/dev/null
        upstream=$(git rev-parse -q --verify '@{u}' 2>/dev/null)
        ahead=0; behind=0
        if [ -n "$upstream" ]; then
          ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
          behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
        fi
        printf 'ahead %s behind %s\\n' "$ahead" "$behind"
        for p in "$@"; do
          if [ -f "$p" ]; then c=$(sha256sum < "$p" | cut -d' ' -f1); else c=-; fi
          if git cat-file -e "HEAD:$p" 2>/dev/null; then h=$(git show "HEAD:$p" | sha256sum | cut -d' ' -f1); else h=-; fi
          printf '%s\\t%s\\t%s\\n' "$c" "$h" "$p"
        done
        """
        return ["sh", "-c", script, "anglesite-sync-probe"] + paths
    }

    /// Parses the probe's stdout. `nil` if it isn't the probe's output at all.
    public static func parseProbe(_ stdout: String) -> (ahead: Int, behind: Int, files: [GuestFileState])? {
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first else { return nil }
        let words = header.split(separator: " ")
        guard words.count == 4, words[0] == "ahead", words[2] == "behind",
              let ahead = Int(words[1]), let behind = Int(words[3])
        else { return nil }
        lines.removeFirst()
        var files: [GuestFileState] = []
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            files.append(GuestFileState(
                path: fields[2],
                current: fields[0] == "-" ? nil : fields[0],
                committed: fields[1] == "-" ? nil : fields[1]))
        }
        return (ahead, behind, files)
    }

    /// `argv` that brings a guest that's behind the host up to the host's `HEAD`. First restores
    /// each file whose content is exactly what this sync last wrote (`lastSynced`): those are
    /// copies of host files, so the host still has them, and leaving them would make git refuse the
    /// fast-forward as local changes. Then fetches the host's branch and fast-forwards, the same as
    /// `git pull --ff-only`. Prints each restored path.
    public static func catchUpArgv(lastSynced: [String: String]) -> [String] {
        let script = """
        while [ $# -gt 1 ]; do
          s=$1; p=$2; shift 2
          if [ -f "$p" ] && [ "$(sha256sum < "$p" | cut -d' ' -f1)" = "$s" ]; then
            git checkout -q -- "$p" 2>/dev/null || rm -f -- "$p"
            printf '%s\\n' "$p"
          fi
        done
        git fetch -q origin && git merge --ff-only -q '@{u}'
        """
        let pairs = lastSynced.sorted { $0.key < $1.key }.flatMap { [$0.value, $0.key] }
        return ["sh", "-c", script, "anglesite-sync-catch-up"] + pairs
    }

    // MARK: - Plan

    /// The host side of one path: its bytes, or `nil` if the host deleted it.
    public struct HostFile: Equatable, Sendable {
        public var path: String
        public var contents: Data?

        public init(path: String, contents: Data?) {
            self.path = path
            self.contents = contents
        }
    }

    /// Decides each path's action. `lastSynced` maps a path to the hash this sync last wrote there,
    /// which is how a guest copy that differs from `HEAD` only because of an earlier sync still
    /// counts as untouched.
    public static func plan(host: [HostFile], guest: [GuestFileState], lastSynced: [String: String]) -> [Action] {
        let guestByPath = Dictionary(guest.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return host.map { file in
            let state = guestByPath[file.path] ?? GuestFileState(path: file.path, current: nil, committed: nil)
            if let contents = file.contents, contents.count > maxFileBytes { return .tooLarge(path: file.path) }
            let hostHash = file.contents.map(sha256)
            if hostHash == state.current { return .unchanged(path: file.path) }
            let untouched = state.current == state.committed
                || (state.current != nil && state.current == lastSynced[file.path])
            guard untouched else { return .conflict(path: file.path) }
            if let hostHash { return .write(path: file.path, sha256: hostHash) }
            return .delete(path: file.path)
        }
    }

    // MARK: - Writes

    /// The `argv`s that write `contents` to `path` in the guest: the first creates the parent
    /// directory and a temp file, middle ones append base64 chunks, the last decodes into place
    /// with a rename, so the dev server never sees a half-written file.
    public static func writeArgvs(path: String, contents: Data) -> [[String]] {
        let encoded = contents.base64EncodedString()
        var chunks: [Substring] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: chunkCharacters, limitedBy: encoded.endIndex) ?? encoded.endIndex
            chunks.append(encoded[index..<end])
            index = end
        }
        if chunks.isEmpty { chunks = [""] }
        let temp = "$1.anglesite-sync"
        var argvs: [[String]] = []
        for (offset, chunk) in chunks.enumerated() {
            let redirect = offset == 0 ? ">" : ">>"
            let prefix = offset == 0 ? "mkdir -p \"$(dirname \"$1\")\" && " : ""
            argvs.append(["sh", "-c", "\(prefix)printf '%s' \"$2\" \(redirect) \"\(temp).b64\"", "anglesite-sync-write", path, String(chunk)])
        }
        argvs.append(["sh", "-c", "base64 -d < \"\(temp).b64\" > \"\(temp)\" && rm -f \"\(temp).b64\" && mv -f \"\(temp)\" \"$1\"", "anglesite-sync-commit", path])
        return argvs
    }

    /// The `argv` that removes `path` in the guest.
    public static func deleteArgv(path: String) -> [String] {
        ["sh", "-c", "rm -f -- \"$1\"", "anglesite-sync-delete", path]
    }

    // MARK: - Run

    /// What one sync did, for logging.
    public struct Outcome: Equatable, Sendable {
        public var written: [String] = []
        public var deleted: [String] = []
        public var conflicts: [String] = []
        public var tooLarge: [String] = []
        public var failed: [String] = []
        /// The guest has commits the host doesn't (editor work not yet saved back), so nothing was
        /// copied this time.
        public var skippedUnsavedGuestWork = false
        /// The guest was behind the host's commits and was fast-forwarded first.
        public var caughtUpWithHostCommits = false
        /// `lastSynced` after this run, for the caller to keep.
        public var lastSynced: [String: String] = [:]

        public init() {}
    }

    /// Runs one sync for `paths` (from ``relevantPaths(in:sourceDirectory:)``). `exec` runs an
    /// `argv` in the guest working copy, as `LocalContainerControl.exec` does. A failure of the
    /// probe itself throws; a failure writing one file is recorded and the rest still go ahead.
    public static func run(
        paths: [String],
        sourceDirectory: URL,
        lastSynced: [String: String],
        exec: ([String]) async throws -> ContainerExecResult
    ) async throws -> Outcome {
        var outcome = Outcome()
        outcome.lastSynced = lastSynced
        guard !paths.isEmpty else { return outcome }

        var paths = paths
        var parsed = try await probe(paths, exec: exec)
        guard parsed.ahead == 0 else {
            outcome.skippedUnsavedGuestWork = true
            return outcome
        }
        if parsed.behind > 0 {
            // The host has commits the guest doesn't (a `git pull`, a commit made in VS Code).
            let caughtUp = try? await exec(catchUpArgv(lastSynced: outcome.lastSynced))
            if let caughtUp, caughtUp.exitCode == 0 {
                outcome.caughtUpWithHostCommits = true
                let restored = caughtUp.stdout.split(separator: "\n").map(String.init)
                for path in restored { outcome.lastSynced[path] = nil }
                // A restored path may still carry an uncommitted host edit: check it again.
                paths = Array(Set(paths).union(restored)).sorted()
                parsed = try await probe(paths, exec: exec)
            }
        }

        let host = paths.map { path in
            HostFile(path: path, contents: readRegularFile(sourceDirectory.appendingPathComponent(path)))
        }
        let contentsByPath = Dictionary(host.map { ($0.path, $0.contents) }, uniquingKeysWith: { first, _ in first })
        for action in plan(host: host, guest: parsed.files, lastSynced: outcome.lastSynced) {
            switch action {
            case .write(let path, let hash):
                guard let contents = contentsByPath[path] ?? nil else { continue }
                var ok = true
                for argv in writeArgvs(path: path, contents: contents) {
                    let result = try? await exec(argv)
                    if result?.exitCode != 0 { ok = false; break }
                }
                if ok {
                    outcome.written.append(path)
                    outcome.lastSynced[path] = hash
                } else {
                    outcome.failed.append(path)
                }
            case .delete(let path):
                let result = try? await exec(deleteArgv(path: path))
                if result?.exitCode == 0 {
                    outcome.deleted.append(path)
                    outcome.lastSynced[path] = nil
                } else {
                    outcome.failed.append(path)
                }
            case .unchanged:
                continue
            case .conflict(let path):
                outcome.conflicts.append(path)
            case .tooLarge(let path):
                outcome.tooLarge.append(path)
            }
        }
        return outcome
    }

    private static func probe(
        _ paths: [String], exec: ([String]) async throws -> ContainerExecResult
    ) async throws -> (ahead: Int, behind: Int, files: [GuestFileState]) {
        let result = try await exec(probeArgv(paths: paths))
        guard result.exitCode == 0, let parsed = parseProbe(result.stdout) else {
            throw ProbeError(exitCode: result.exitCode, detail: result.stderr)
        }
        return parsed
    }

    /// The probe didn't run, or printed something other than its own output.
    public struct ProbeError: Error, Equatable {
        public var exitCode: Int32
        public var detail: String
    }

    /// The file's bytes, or `nil` if it's missing or not a regular file (a directory event).
    static func readRegularFile(_ url: URL) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return try? Data(contentsOf: url)
    }

    static func sha256(_ data: Data) -> String {
        PortableSHA256.hexDigest(of: data)
    }
}
