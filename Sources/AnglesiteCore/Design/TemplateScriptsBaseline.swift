import Foundation

/// Reads/writes `Config/template-scripts-baseline.json` — a per-file content-hash snapshot the
/// app-owned-file refresh mechanism (design doc, #1053; extended to `src/lib/` by #1426) uses to
/// tell "stale" apart from "this copy had been changed." App-owned state, never committed to the
/// site's git repo (`Config/` sits outside `Source/` — see the `.anglesite` package model),
/// mirroring `Config/dependency-baseline.json`'s placement rationale.
///
/// Since #1962 (owner decision D1, 2026-09-08) the distinction is informational only — the app
/// restores every app-owned file to its own copy either way, and only the wording it reports
/// differs ("updated" vs "restored"). The pre-#1962 `acknowledgedTemplateHash` field (a
/// "keep my version" the owner once chose) is no longer read or written; a baseline file that
/// still carries it decodes fine (unknown keys are ignored) and the old choice is simply not
/// honored, per D1/D5: keep-mine is never offered for an app-owned file.
public struct TemplateScriptsBaseline: Codable, Equatable, Sendable {
    /// The baseline record for one app-owned file (`scripts/` or `src/lib/`): the last reconciled
    /// template content hash.
    public struct Entry: Codable, Equatable, Sendable {
        /// Hash (`VectorMath.stableHash`) of the template content this file was last
        /// successfully reconciled against — at scaffold time, at a prior silent refresh, or
        /// backfilled from the site's own content the first time this mechanism inspected it.
        public var baselineHash: String

        /// Creates an entry for a freshly reconciled file.
        public init(baselineHash: String) {
            self.baselineHash = baselineHash
        }

        private enum CodingKeys: String, CodingKey { case baselineHash }
    }

    /// The baseline's filename inside `Config/` — public so tests and diagnostics can locate the
    /// file without duplicating the string.
    public static let filename = "template-scripts-baseline.json"

    /// One ``Entry`` per app-owned file, keyed by template-relative path (e.g.
    /// `scripts/pre-deploy-check.ts`). A missing key means the file was never reconciled — the
    /// checker backfills it on first encounter.
    public var files: [String: Entry]

    /// Creates a baseline; the empty default is the never-recorded state ``load(from:)`` also
    /// falls back to.
    public init(files: [String: Entry] = [:]) {
        self.files = files
    }

    /// Never fails — an absent or corrupt baseline file reads as "no baseline recorded for any
    /// file yet," which is exactly the legacy-site case the checker already handles explicitly.
    public static func load(from configDirectory: URL) -> TemplateScriptsBaseline {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TemplateScriptsBaseline.self, from: data)
        else { return TemplateScriptsBaseline() }
        return decoded
    }

    /// Writes the baseline atomically into `configDirectory` — unlike ``load(from:)`` this does
    /// throw, since silently losing a just-reconciled baseline would re-prompt the owner about
    /// divergences they already resolved.
    public func save(to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(Self.filename)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
