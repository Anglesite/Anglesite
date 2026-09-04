import Foundation

/// Enumerates the exact set of files this refresh mechanism keeps current in a site (the
/// "app-owned" set, design doc §Scope): everything `scripts/scaffold.sh`'s `rsync` copies from
/// `Resources/Template/scripts/`, plus every file under `Resources/Template/src/lib/` — pure
/// framework logic (`robots-config.ts`, `rsl.ts`, `licensing.ts`, `embed-card.ts`, etc.) that
/// several app-owned scripts (`edge-artifacts.ts`, `csp.ts`, `pre-deploy-check.ts`,
/// `remark-embeds.ts`) import at build time. `src/lib/` is not "site content" the way
/// `src/data/`, `src/content/`, and `src/pages/` are — no site ever customizes it, and
/// `scaffold.sh` copies it wholesale with no excludes of its own, so it belongs in the same
/// app-owned set as `scripts/` rather than behind #745's general "`src/` is out of scope"
/// boundary (which is about site content, not this directory). Mirrors `scaffold.sh`'s own
/// exclude list (`Resources/Template/scripts/scaffold.sh:33-43`) rather than re-parsing the shell
/// script; the two lists are kept in sync by hand, the same way every other template-path
/// consumer (`TemplateRuntime`, `ThemeCatalog`) already duplicates path knowledge rather than
/// sharing it with the shell script.
public enum TemplateScriptsManifest {
    /// Names excluded only when they sit directly inside `scripts/` itself — matches rsync's own
    /// anchoring rules for a pattern containing a slash (`scripts/themes.ts` does not match
    /// `scripts/embeds/themes.ts`). The `.test.ts` suffix exclusion below is applied with the same
    /// top-level-only restriction, deliberately reproducing the anchoring quirk `scaffold.sh` has
    /// today (design doc §Scope) rather than silently fixing it as a side effect of this feature.
    /// `check-pack.ts` and `build-packs.sh` are pack-authoring tooling `scaffold.sh` never ships
    /// to a site at all (its own exclude list drops both) — this set must match that exactly, or
    /// this mechanism ships a file into every site whose imports (`./themes`, correctly excluded
    /// below) were never migrated alongside it.
    private static let scriptsTopLevelExcludedNames: Set<String> = [
        "scaffold.sh", "themes.ts", "themes.json", "check-pack.ts", "build-packs.sh",
    ]

    /// Relative paths (e.g. `"scripts/pre-deploy-check.ts"`, `"scripts/embeds/adapters.ts"`,
    /// `"src/lib/robots-config.ts"`), sorted for deterministic iteration order. Returns `[]` if
    /// neither `templateRoot/scripts` nor `templateRoot/src/lib` exists or can be enumerated.
    public static func appOwnedRelativePaths(templateRoot: URL) -> [String] {
        var results = enumerate(
            root: templateRoot.appendingPathComponent("scripts"),
            relativePrefix: "scripts",
            topLevelExcludedNames: scriptsTopLevelExcludedNames,
            excludeTopLevelTestFiles: true
        )
        // `scaffold.sh` has no `src/lib/*` excludes at all (not even `.test.ts` files — those are
        // shipped and run as part of every site's own `npm test`), so nothing is excluded here
        // beyond `.DS_Store`.
        results += enumerate(
            root: templateRoot.appendingPathComponent("src/lib"),
            relativePrefix: "src/lib",
            topLevelExcludedNames: [],
            excludeTopLevelTestFiles: false
        )
        return results.sorted()
    }

    private static func enumerate(
        root: URL,
        relativePrefix: String,
        topLevelExcludedNames: Set<String>,
        excludeTopLevelTestFiles: Bool
    ) -> [String] {
        // No `.skipsHiddenFiles`: rsync's `--exclude='.DS_Store'` has no slash, so per rsync's own
        // anchoring rules it matches at *any* depth, not just top-level — but it names only that
        // one file. `.skipsHiddenFiles` would instead drop every dotfile at every depth, which is
        // a wider exclusion than `scaffold.sh` actually applies. `.DS_Store` is matched by name
        // below instead, keeping this manifest exact rather than incidentally broader.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var results: [String] = []
        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            if fileURL.lastPathComponent == ".DS_Store" { continue }

            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath + "/") else { continue }
            let relativeToRoot = String(standardizedPath.dropFirst(rootPath.count + 1))

            let isTopLevel = !relativeToRoot.contains("/")
            if isTopLevel && topLevelExcludedNames.contains(relativeToRoot) { continue }
            if isTopLevel && excludeTopLevelTestFiles && relativeToRoot.hasSuffix(".test.ts") { continue }

            results.append(relativePrefix + "/" + relativeToRoot)
        }
        return results
    }
}
