// Sources/AnglesiteCore/Design/DesignApplyService.swift
import Foundation

/// One design-apply request: the CSS tokens to write plus the human-readable documents that
/// record why the design looks the way it does. Keeping the docs alongside the tokens means a
/// design is never applied without its rationale landing in the repo too.
public struct DesignApplyInput: Sendable {
    /// CSS custom properties to upsert into `global.css`'s top-level `:root` block, keyed
    /// *without* the `--` prefix (``DesignApplyService`` adds it). Empty means "no CSS change" —
    /// the docs are still written (see the inline note in `apply`).
    public let cssVars: [String: String]
    /// Full design rationale for `docs/DESIGN.md`; `nil` skips that file entirely (the file is
    /// overwritten, not appended — it documents the *current* design).
    public let rationaleMarkdown: String?
    /// Short brand description appended to `docs/brand.md` under a ``sourceLabel`` heading —
    /// appended, not overwritten, so the brand doc accumulates a history of applied designs.
    public let brandSummary: String
    /// Names the flow that produced this design (e.g. `design-interview`); becomes the heading
    /// of the `docs/brand.md` entry so successive applies stay attributable to their source.
    public let sourceLabel: String
    /// ``DesignContextDocument/render(axes:cssVars:brandVoicePreamble:freedesignmdSystem:appliedThemeOrPackID:)``'s
    /// output for `Source/DESIGN.md`, when the caller wants that file (re)generated; `nil` skips
    /// it entirely. Regenerated only when the file is absent or still owned by this generator —
    /// see ``GeneratedDesignDocument``.
    public let designContextMarkdown: String?
    /// ``ProductContextDocument/render(displayName:businessType:siteType:audienceAndIntentNotes:)``'s
    /// output for `Source/PRODUCT.md`, under the same ownership gate as ``designContextMarkdown``.
    public let productContextMarkdown: String?

    /// Memberwise initializer — public so both design flows (theme wizard and interview) can
    /// build inputs from outside this file. `designContextMarkdown`/`productContextMarkdown`
    /// default to `nil` so existing call sites that don't render those documents are unaffected.
    public init(
        cssVars: [String: String], rationaleMarkdown: String?, brandSummary: String, sourceLabel: String,
        designContextMarkdown: String? = nil, productContextMarkdown: String? = nil
    ) {
        self.cssVars = cssVars; self.rationaleMarkdown = rationaleMarkdown
        self.brandSummary = brandSummary; self.sourceLabel = sourceLabel
        self.designContextMarkdown = designContextMarkdown; self.productContextMarkdown = productContextMarkdown
    }
}

/// Receipt of a successful apply — what changed, for callers to surface in confirmation UI.
public struct AppliedDesign: Sendable, Equatable {
    /// The CSS vars that were written (echoes the input's `cssVars`; empty when the apply was
    /// docs-only).
    public let updatedVars: [String: String]
    /// `Source/`-relative paths of every file written, in write order.
    public let writtenFiles: [String]
    /// One-line notices for a generated document (`DESIGN.md`/`PRODUCT.md`) that was requested
    /// but left untouched because it's been hand-edited since the last apply — see
    /// ``GeneratedDesignDocument``. Empty when every requested document was writable, and always
    /// empty for callers who don't pass those documents at all — defaulted so existing
    /// `AppliedDesign(updatedVars:writtenFiles:)` call sites keep compiling unchanged.
    public let skippedNotices: [String]

    /// Explicit initializer (rather than the implicit memberwise one, which a `public` struct
    /// only gets `internal`) with `skippedNotices` defaulted so pre-#1947 call sites that built
    /// this with just `updatedVars`/`writtenFiles` keep compiling unchanged.
    public init(updatedVars: [String: String], writtenFiles: [String], skippedNotices: [String] = []) {
        self.updatedVars = updatedVars; self.writtenFiles = writtenFiles; self.skippedNotices = skippedNotices
    }
}

/// Why an apply failed. Distinguishes "the template file the tokens live in is missing or
/// malformed" (the first two cases — nothing was written) from a mid-write I/O failure, where
/// knowing what *did* get written matters.
public enum DesignApplyError: Error, Sendable, Equatable {
    /// `src/styles/global.css` couldn't be read — without it there is nowhere to put the tokens.
    case missingGlobalCSS
    /// `global.css` exists but has no top-level `:root { }` block to upsert into; the service
    /// refuses to guess a scope rather than inject tokens somewhere they'd be shadowed.
    case missingRootBlock
    /// A write failed partway. `partiallyWritten` lists the `Source/`-relative paths already on
    /// disk, so callers can report exactly what changed instead of implying nothing did.
    case writeFailed(message: String, partiallyWritten: [String])
}

/// The single writer for applying a design to a site's `Source/` directory — shared by the
/// built-in/freedesignmd theme-apply wizard and (later) the design-interview conversation, so
/// there is exactly one "write design to disk" implementation.
public enum DesignApplyService {
    static let globalCSSRelativePath = "src/styles/global.css"
    static let rationaleRelativePath = "docs/DESIGN.md"
    static let brandRelativePath = "docs/brand.md"
    static let designContextRelativePath = "DESIGN.md"
    static let productContextRelativePath = "PRODUCT.md"

    /// Applies `input` to a site's `Source/` directory: upserts the CSS vars into `global.css`
    /// (skipped when `cssVars` is empty — see the inline note), overwrites `docs/DESIGN.md` with
    /// the rationale, appends the brand summary to `docs/brand.md`, and (re)generates the
    /// root-level `DESIGN.md`/`PRODUCT.md` agent-context documents when the caller provides them —
    /// skipping either one, with a note in ``AppliedDesign/skippedNotices``, if it's been
    /// hand-edited since this generator last wrote it (see ``GeneratedDesignDocument``). The two
    /// root-level documents are a distinct artifact from `docs/DESIGN.md`: that file is an
    /// owner-facing rationale for *this* apply, while `Source/DESIGN.md` is a living, external-
    /// agent-facing summary of the site's *current* design (#1947).
    ///
    /// Returns `Result` rather than throwing so the partial-write list travels with the failure
    /// (see ``DesignApplyError/writeFailed(message:partiallyWritten:)``). The CSS write happens
    /// first: it's the one step that can fail *before* writing anything, so a failure there
    /// leaves the site untouched.
    public static func apply(
        _ input: DesignApplyInput,
        to sourceDirectory: URL,
        fileManager: FileManager = .default
    ) -> Result<AppliedDesign, DesignApplyError> {
        // An empty `cssVars` means the caller has no CSS tokens to write (e.g. the freedesignmd
        // wizard flow, whose token translation is currently stubbed — see ThemeApplyWizardModel).
        // Skip the global.css read/upsert/write entirely in that case: there is nothing to
        // change, so this flow must not hard-fail just because global.css or its `:root` block
        // is missing or malformed.
        if !input.cssVars.isEmpty {
            let cssURL = sourceDirectory.appendingPathComponent(globalCSSRelativePath)
            guard let original = try? String(contentsOf: cssURL, encoding: .utf8) else {
                return .failure(.missingGlobalCSS)
            }
            guard let updatedCSS = upsertRootVars(input.cssVars, in: original) else {
                return .failure(.missingRootBlock)
            }
            do {
                try updatedCSS.write(to: cssURL, atomically: true, encoding: .utf8)
            } catch {
                return .failure(.writeFailed(message: (error as NSError).localizedDescription, partiallyWritten: []))
            }
        }

        var written: [String] = input.cssVars.isEmpty ? [] : [globalCSSRelativePath]
        var notices: [String] = []
        do {
            if let rationaleMarkdown = input.rationaleMarkdown {
                let rationaleURL = sourceDirectory.appendingPathComponent(rationaleRelativePath)
                try fileManager.createDirectory(at: rationaleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rationaleMarkdown.write(to: rationaleURL, atomically: true, encoding: .utf8)
                written.append(rationaleRelativePath)
            }

            let brandURL = sourceDirectory.appendingPathComponent(brandRelativePath)
            try fileManager.createDirectory(at: brandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existingBrand = (try? String(contentsOf: brandURL, encoding: .utf8)) ?? ""
            let entry = "\n## \(input.sourceLabel)\n\n\(input.brandSummary)\n"
            try (existingBrand + entry).write(to: brandURL, atomically: true, encoding: .utf8)
            written.append(brandRelativePath)

            if let designContextMarkdown = input.designContextMarkdown {
                if let notice = try writeGeneratedDocument(
                    designContextMarkdown, relativePath: designContextRelativePath,
                    to: sourceDirectory, fileManager: fileManager, written: &written
                ) { notices.append(notice) }
            }
            if let productContextMarkdown = input.productContextMarkdown {
                if let notice = try writeGeneratedDocument(
                    productContextMarkdown, relativePath: productContextRelativePath,
                    to: sourceDirectory, fileManager: fileManager, written: &written
                ) { notices.append(notice) }
            }
        } catch {
            return .failure(.writeFailed(message: (error as NSError).localizedDescription, partiallyWritten: written))
        }

        return .success(AppliedDesign(updatedVars: input.cssVars, writtenFiles: written, skippedNotices: notices))
    }

    /// Writes `markdown` to `relativePath` unless a hand-edited file is already there — absent or
    /// still owned by this generator (``GeneratedDesignDocument/isOwned(_:)``) means safe to
    /// (re)write; anything else is left untouched and reported back as a one-line notice instead.
    private static func writeGeneratedDocument(
        _ markdown: String, relativePath: String, to sourceDirectory: URL,
        fileManager: FileManager, written: inout [String]
    ) throws -> String? {
        let url = sourceDirectory.appendingPathComponent(relativePath)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing == nil || GeneratedDesignDocument.isOwned(existing) else {
            return "\(relativePath) has been edited by hand — leaving it as-is."
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        written.append(relativePath)
        return nil
    }

    /// Replaces or appends `--<key>: <value>;` lines inside the top-level `:root { ... }` block,
    /// leaving everything else in the file untouched. Returns `nil` if no top-level `:root` block
    /// is found.
    static func upsertRootVars(_ vars: [String: String], in css: String) -> String? {
        guard let (openBrace, closeBrace) = topLevelRootBlockRange(in: css) else { return nil }

        var body = String(css[openBrace..<closeBrace])
        var remaining = vars

        for key in vars.keys {
            // Replace every occurrence, not just the first: a hand-edited `:root` block can
            // declare the same custom property twice, and CSS gives the *last* declaration
            // precedence — leaving an earlier duplicate stale would silently keep the old value
            // in effect even though this function reports the var as updated.
            let pattern = #"(--\#(NSRegularExpression.escapedPattern(for: key))\s*:\s*)[^;]*;"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            let matches = re.matches(in: body, range: range)
            guard !matches.isEmpty else { continue }
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: body) else { continue }
                body.replaceSubrange(matchRange, with: "--\(key): \(vars[key]!);")
            }
            remaining.removeValue(forKey: key)
        }

        if !remaining.isEmpty {
            let additions = remaining.sorted(by: { $0.key < $1.key })
                .map { "  --\($0.key): \($0.value);" }.joined(separator: "\n")
            if !body.hasSuffix("\n") { body += "\n" }
            body += additions + "\n"
        }

        return String(css[css.startIndex..<openBrace]) + body + String(css[closeBrace...])
    }

    /// Scans `css` for the first `:root { ... }` rule declared at the top level of the
    /// stylesheet (brace depth 0), returning the range of its body (between the braces,
    /// exclusive). Skips `:root` occurrences that are:
    /// - part of a compound selector, e.g. `:root[data-theme="dark"]` (no `{` immediately
    ///   after `:root`, modulo whitespace), or
    /// - nested inside another block, e.g. a `:root` re-declared inside
    ///   `@media (prefers-color-scheme: dark) { :root { ... } }` — a plain substring/regex
    ///   search for `:root` can't tell this apart from the real top-level rule, and would
    ///   silently upsert tokens into the wrong scope.
    static func topLevelRootBlockRange(in css: String) -> (open: String.Index, close: String.Index)? {
        var depth = 0
        var i = css.startIndex
        while i < css.endIndex {
            let c = css[i]
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
            } else if depth == 0, css[i...].hasPrefix(":root") {
                var j = css.index(i, offsetBy: 5)
                while j < css.endIndex, css[j].isWhitespace { j = css.index(after: j) }
                if j < css.endIndex, css[j] == "{" {
                    guard let close = matchingCloseBrace(in: css, openingAt: j) else { return nil }
                    return (css.index(after: j), close)
                }
            }
            i = css.index(after: i)
        }
        return nil
    }

    /// Finds the index of the `}` that closes the `{` at `openBrace`, accounting for nested
    /// braces inside the block.
    private static func matchingCloseBrace(in css: String, openingAt openBrace: String.Index) -> String.Index? {
        var depth = 1
        var k = css.index(after: openBrace)
        while k < css.endIndex {
            if css[k] == "{" { depth += 1 }
            else if css[k] == "}" {
                depth -= 1
                if depth == 0 { return k }
            }
            k = css.index(after: k)
        }
        return nil
    }
}

public extension DesignApplyService {
    /// Package-typed convenience: resolves the `.anglesite` package's `Source/` directory and
    /// applies there, so callers holding an `AnglesitePackage` don't reach into its layout
    /// themselves.
    static func apply(
        _ input: DesignApplyInput,
        to package: AnglesitePackage,
        fileManager: FileManager = .default
    ) -> Result<AppliedDesign, DesignApplyError> {
        apply(input, to: package.sourceURL, fileManager: fileManager)
    }
}
