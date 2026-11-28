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
/// 1. a **probe** (one guest `exec`) reporting, per changed path, the guest file's hash, the hash
///    of the guest's committed version and whether git ignores the path, plus how far the guest
///    is ahead of / behind the host's branch;
/// 2. a **catch-up** when the host has commits the guest lacks: files this sync copied are
///    restored, the guest fast-forwards, and the restored paths are checked again;
/// 3. a **plan**: copy a host file into the guest only when the guest's copy is untouched, i.e. it
///    still matches the guest's `HEAD`, or is exactly what this sync last wrote (or removed). A
///    guest copy changed some other way (an edit in progress inside the guest) is kept, and the
///    batch reports a conflict. If the guest has commits the host lacks (editor work not yet saved
///    back), nothing is copied; the caller keeps the paths and retries them later;
/// 4. **writes** (content as base64 in argv chunks, staged under the guest's `.git/` and renamed
///    into place with the host file's mode) and deletes.
///
/// What it never carries: `.git`, generated/dependency directories (`SiteIndexPaths`), anything
/// the site's `.gitignore` excludes, secret files (`.env*`, `.dev.vars*`) whatever the ignore file
/// says, symlinks, and any path that resolves outside `Source/`. It never merges, and never asks
/// the owner about git: an unsafe copy is skipped and logged.
public enum HostSourceSync {
    /// The probe's verdict for one path, as the guest sees it.
    public struct GuestFileState: Equatable, Sendable {
        public var path: String
        /// SHA-256 (hex) of the guest's working-tree file, or `nil` if it doesn't exist.
        public var current: String?
        /// SHA-256 (hex) of the file as committed at the guest's `HEAD`, or `nil` if not committed.
        public var committed: String?
        /// The site's `.gitignore` excludes it.
        public var ignored: Bool

        public init(path: String, current: String?, committed: String?, ignored: Bool = false) {
            self.path = path
            self.current = current
            self.committed = committed
            self.ignored = ignored
        }
    }

    /// The host side of one path.
    public enum HostFile: Equatable, Sendable {
        /// A regular file inside `Source/`, with its permission bits (e.g. `"644"`).
        case regular(path: String, contents: Data, mode: String)
        /// Deleted on the host.
        case missing(path: String)
        /// A symlink, or a path whose real location is outside `Source/`. Never read.
        case unsafe(path: String)
        /// A directory or other non-file (a directory event). Nothing to carry.
        case other(path: String)

        public var path: String {
            switch self {
            case .regular(let path, _, _), .missing(let path), .unsafe(let path), .other(let path): path
            }
        }
    }

    /// What one sync decided for one path.
    public enum Action: Equatable, Sendable {
        /// Write the host's bytes to the guest. `sha256` is their hash, recorded once written.
        case write(path: String, sha256: String)
        /// Remove the guest's file; the host deleted it.
        case delete(path: String)
        /// The guest already has exactly this, or there's nothing to carry.
        case unchanged(path: String)
        /// The guest's copy changed since the last sync or commit, so it's kept.
        case conflict(path: String)
        /// Too large to carry this way.
        case tooLarge(path: String)
        /// Ignored by the site's `.gitignore`, so never carried.
        case ignored(path: String)
        /// A symlink or a path resolving outside `Source/`, so never read.
        case unsafe(path: String)
    }

    /// Files bigger than this aren't carried (base64 in argv chunks gets slow well before this).
    public static let maxFileBytes = 16 * 1024 * 1024

    /// Base64 characters per `exec` argument: under Linux's 128 KiB `MAX_ARG_STRLEN`.
    static let chunkCharacters = 96 * 1024

    /// The guest working copy every script runs in.
    public static let guestWorkingDirectory = "/workspace/site"

    /// `lastSynced` value for a path this sync deleted, so restoring it later isn't mistaken for a
    /// guest-side edit.
    public static let tombstone = "-"

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

    /// Never `.git` (in any form), a skipped generated/dependency directory, a secret file, or a
    /// path that could escape the working copy.
    static func isCarried(_ relative: String) -> Bool {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\u{0}") })
        else { return false }
        if components.contains(".git") { return false }
        if let name = components.last, isSecretFile(String(name)) { return false }
        return !SiteIndexPaths.isSkipped(relativePath: relative)
    }

    /// `.env`, `.env.*`, `.dev.vars`, `.dev.vars.*` — kept out of the guest even if a site's
    /// `.gitignore` forgot them.
    static func isSecretFile(_ name: String) -> Bool {
        name == ".env" || name.hasPrefix(".env.") || name == ".dev.vars" || name.hasPrefix(".dev.vars.")
    }

    // MARK: - Host

    /// Reads one host path without following symlinks, refusing anything whose real location is
    /// outside `sourceDirectory` (an intermediate directory symlink, say).
    public static func readHostFile(_ path: String, sourceDirectory: URL, fileManager: FileManager = .default) -> HostFile {
        let url = sourceDirectory.appendingPathComponent(path)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            // Gone — unless a parent is a dangling or escaping symlink, which still counts as unsafe.
            return isInside(url.deletingLastPathComponent(), sourceDirectory) ? .missing(path: path) : .unsafe(path: path)
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return .unsafe(path: path) }
        guard isInside(url, sourceDirectory) else { return .unsafe(path: path) }
        guard type == .typeRegular else { return .other(path: path) }
        guard let contents = try? Data(contentsOf: url) else { return .missing(path: path) }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return .regular(path: path, contents: contents, mode: String(permissions & 0o777, radix: 8))
    }

    /// Whether `url`'s real location (symlinks resolved) is `root` or inside it.
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/")
    }

    // MARK: - Probe

    /// `argv` for the probe. Prints NUL-terminated records: first `ahead <n> behind <m>` — the
    /// guest's commits not on the host's branch (`origin`, the read-only host share) and the host's
    /// commits not in the guest — then one per path: `<current|->\t<committed|->\t<0|1 ignored>\t<path>`.
    /// A failed `git fetch` still reports on stderr.
    public static func probeArgv(paths: [String]) -> [String] {
        let script = """
        git fetch -q origin || true
        upstream=$(git rev-parse -q --verify '@{u}' 2>/dev/null)
        ahead=0; behind=0
        if [ -n "$upstream" ]; then
          ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
          behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
        fi
        printf 'ahead %s behind %s\\0' "$ahead" "$behind"
        for p in "$@"; do
          if [ -f "$p" ] && [ ! -L "$p" ]; then c=$(sha256sum < "$p" | cut -d' ' -f1); else c=-; fi
          if git cat-file -e "HEAD:$p" 2>/dev/null; then h=$(git show "HEAD:$p" | sha256sum | cut -d' ' -f1); else h=-; fi
          if git check-ignore -q -- "$p" 2>/dev/null; then i=1; else i=0; fi
          printf '%s\\t%s\\t%s\\t%s\\0' "$c" "$h" "$i" "$p"
        done
        """
        return ["sh", "-c", script, "anglesite-sync-probe"] + paths
    }

    /// Parses the probe's stdout. `nil` if it isn't the probe's output at all.
    public static func parseProbe(_ stdout: String) -> (ahead: Int, behind: Int, files: [GuestFileState])? {
        var records = stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        guard let header = records.first else { return nil }
        let words = header.split(separator: " ")
        guard words.count == 4, words[0] == "ahead", words[2] == "behind",
              let ahead = Int(words[1]), let behind = Int(words[3])
        else { return nil }
        records.removeFirst()
        var files: [GuestFileState] = []
        for record in records {
            let fields = record.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            files.append(GuestFileState(
                path: fields[3],
                current: fields[0] == "-" ? nil : fields[0],
                committed: fields[1] == "-" ? nil : fields[1],
                ignored: fields[2] == "1"))
        }
        return (ahead, behind, files)
    }

    // MARK: - Catch-up

    /// `argv` that brings a guest that's behind the host up to the host's `HEAD`. First puts back
    /// each file this sync changed (`lastSynced`) — a copy whose content is still exactly what it
    /// wrote, or a deletion that's still missing — since the host still has those, and git would
    /// refuse the fast-forward over them as local changes. A tracked file is restored from `HEAD`;
    /// one that can't be fails the whole step rather than being deleted. Then fetches the host's
    /// branch and fast-forwards, the same as `git pull --ff-only`. Prints each restored path,
    /// NUL-terminated, even when the fast-forward then fails.
    public static func catchUpArgv(lastSynced: [String: String]) -> [String] {
        let script = """
        while [ $# -gt 1 ]; do
          s=$1; p=$2; shift 2
          if [ "$s" = "-" ]; then
            [ -e "$p" ] && continue
          else
            [ -f "$p" ] && [ "$(sha256sum < "$p" | cut -d' ' -f1)" = "$s" ] || continue
          fi
          if git cat-file -e "HEAD:$p" 2>/dev/null; then
            git checkout -q -- "$p" || exit 3
          else
            rm -f -- "$p"
          fi
          printf '%s\\0' "$p"
        done
        git fetch -q origin && git merge --ff-only -q '@{u}'
        """
        let pairs = lastSynced.sorted { $0.key < $1.key }.flatMap { [$0.value, $0.key] }
        return ["sh", "-c", script, "anglesite-sync-catch-up"] + pairs
    }

    /// The restored paths a catch-up printed, whether or not it then succeeded.
    public static func restoredPaths(fromCatchUp stdout: String) -> [String] {
        stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Plan

    /// Decides each path's action. `lastSynced` maps a path to the hash this sync last wrote there
    /// (or ``tombstone`` for a deletion), which is how a guest copy that differs from `HEAD` only
    /// because of an earlier sync still counts as untouched.
    public static func plan(host: [HostFile], guest: [GuestFileState], lastSynced: [String: String]) -> [Action] {
        let guestByPath = Dictionary(guest.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return host.map { file in
            let path = file.path
            let state = guestByPath[path] ?? GuestFileState(path: path, current: nil, committed: nil)
            let contents: Data?
            switch file {
            case .unsafe: return .unsafe(path: path)
            case .other: return .unchanged(path: path)
            case .missing: contents = nil
            case .regular(_, let data, _): contents = data
            }
            if state.ignored { return .ignored(path: path) }
            if let contents, contents.count > maxFileBytes { return .tooLarge(path: path) }
            let hostHash = contents.map(sha256)
            if hostHash == state.current { return .unchanged(path: path) }
            let synced = lastSynced[path]
            let untouched = state.current == state.committed
                || (state.current != nil && state.current == synced)
                || (state.current == nil && synced == tombstone)
            guard untouched else { return .conflict(path: path) }
            if let hostHash { return .write(path: path, sha256: hostHash) }
            return .delete(path: path)
        }
    }

    // MARK: - Writes

    /// The `argv`s that write `contents` to `path` in the guest with permission bits `mode`. Chunks
    /// are staged under the guest's `.git/anglesite-sync/` (invisible to git and the dev server, on
    /// the same filesystem), then decoded and renamed into place, so the dev server never sees a
    /// half-written file. The last step removes the staging files whether it succeeded or not.
    public static func writeArgvs(path: String, contents: Data, mode: String = "644") -> [[String]] {
        let encoded = contents.base64EncodedString()
        var chunks: [Substring] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: chunkCharacters, limitedBy: encoded.endIndex) ?? encoded.endIndex
            chunks.append(encoded[index..<end])
            index = end
        }
        if chunks.isEmpty { chunks = [""] }
        let id = stagingID(path)
        var argvs: [[String]] = []
        for (offset, chunk) in chunks.enumerated() {
            let redirect = offset == 0 ? ">" : ">>"
            argvs.append(["sh", "-c",
                "d=\"$(git rev-parse --git-dir)/anglesite-sync\" && mkdir -p \"$d\" && printf '%s' \"$2\" \(redirect) \"$d/$1.b64\"",
                "anglesite-sync-write", id, String(chunk)])
        }
        argvs.append(["sh", "-c", """
            d="$(git rev-parse --git-dir)/anglesite-sync"; t="$d/$2"
            mkdir -p "$(dirname "$1")" && base64 -d < "$t.b64" > "$t" && chmod "$3" "$t" && mv -f "$t" "$1"
            rc=$?; rm -f "$t" "$t.b64"; exit $rc
            """, "anglesite-sync-commit", path, id, mode])
        return argvs
    }

    /// Removes a write's staging files after a chunk failed.
    public static func cleanupArgv(path: String) -> [String] {
        ["sh", "-c", "d=\"$(git rev-parse --git-dir)/anglesite-sync\"; rm -f \"$d/$1\" \"$d/$1.b64\"", "anglesite-sync-cleanup", stagingID(path)]
    }

    /// A staging file name for `path`: its hash, so any path maps to a safe, flat name.
    static func stagingID(_ path: String) -> String {
        sha256(Data(path.utf8))
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
        public var ignored: [String] = []
        public var unsafe: [String] = []
        public var failed: [String] = []
        /// The guest has commits the host doesn't (editor work not yet saved back), so nothing was
        /// copied this time. The caller should retry these paths once that work is saved.
        public var skippedUnsavedGuestWork = false
        /// The guest was behind the host's commits and was fast-forwarded first.
        public var caughtUpWithHostCommits = false
        /// The guest was behind, but fast-forwarding failed; what git said.
        public var catchUpFailure: String?
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
            let result: ContainerExecResult
            do {
                result = try await exec(catchUpArgv(lastSynced: outcome.lastSynced))
            } catch {
                result = ContainerExecResult(exitCode: -1, stdout: "", stderr: "\(error)")
            }
            // Whatever happened next, these were put back: forget them and check them again, so an
            // uncommitted host edit among them is copied back rather than left reverted.
            let restored = restoredPaths(fromCatchUp: result.stdout)
            for path in restored { outcome.lastSynced[path] = nil }
            if result.exitCode == 0 {
                outcome.caughtUpWithHostCommits = true
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome.catchUpFailure = detail.isEmpty ? "exit \(result.exitCode)" : detail
            }
            paths = Array(Set(paths).union(restored)).sorted()
            parsed = try await probe(paths, exec: exec)
        }

        let host = paths.map { readHostFile($0, sourceDirectory: sourceDirectory) }
        let hostByPath = Dictionary(host.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for action in plan(host: host, guest: parsed.files, lastSynced: outcome.lastSynced) {
            switch action {
            case .write(let path, let hash):
                guard case .regular(_, let contents, let mode)? = hostByPath[path] else { continue }
                var ok = true
                for argv in writeArgvs(path: path, contents: contents, mode: mode) {
                    let result = try? await exec(argv)
                    if result?.exitCode != 0 { ok = false; break }
                }
                if ok {
                    outcome.written.append(path)
                    outcome.lastSynced[path] = hash
                } else {
                    _ = try? await exec(cleanupArgv(path: path))
                    outcome.failed.append(path)
                }
            case .delete(let path):
                let result = try? await exec(deleteArgv(path: path))
                if result?.exitCode == 0 {
                    outcome.deleted.append(path)
                    outcome.lastSynced[path] = tombstone
                } else {
                    outcome.failed.append(path)
                }
            case .unchanged:
                continue
            case .conflict(let path):
                outcome.conflicts.append(path)
            case .tooLarge(let path):
                outcome.tooLarge.append(path)
            case .ignored(let path):
                outcome.ignored.append(path)
            case .unsafe(let path):
                outcome.unsafe.append(path)
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

    static func sha256(_ data: Data) -> String {
        PortableSHA256.hexDigest(of: data)
    }
}
