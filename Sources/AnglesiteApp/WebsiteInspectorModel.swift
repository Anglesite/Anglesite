import Foundation
import Observation
import AnglesiteCore

/// Data model behind the Website inspector panel (#714 v2 slice 1) — the site-identity basics
/// (title, language, domain, stylesheets) surfaced outside the deep Website Settings sheet.
/// Deliberately thin: no conflict-detection machinery here (the deep editor,
/// `PlistEditorModel`, still owns that) — this is a quick-glance/quick-edit surface over the
/// same on-disk sources.
@MainActor
@Observable
final class WebsiteInspectorModel {
    /// The `.anglesite` package root this inspector reads/writes.
    let packageURL: URL
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Bindable; compared against `savedTitle` to determine dirtiness.
    var title = ""
    private var savedTitle = ""
    /// Bindable; compared against `savedLang` to determine dirtiness.
    var lang = "en"
    private var savedLang = "en"
    /// `nil` when the site has no `DOMAIN` configured. Read-only here — domain configuration
    /// lives in the deep Website Settings sheet, not this quick-glance inspector.
    private(set) var domain: String?
    /// `SiteFileTree.scan`'s `.styles` group for this site, or empty if none.
    private(set) var stylesheets: [FileRef] = []
    private(set) var saveError: String?
    /// True while `saveTitle()`'s off-main read-modify-write is in flight — guards against a
    /// double-fire (e.g. a field commit racing a window close) launching two concurrent writes
    /// to the same `Info.plist`. Mirrors `PlistEditorModel.isSavingLang`'s role for its sibling.
    private(set) var isSavingTitle = false
    /// Same guard as `isSavingTitle`, for `saveLang()`'s `.site-config` write.
    private(set) var isSavingLang = false

    /// True while either bindable field has an edit not yet saved.
    var isDirty: Bool { isTitleDirty || isLangDirty }
    private var isTitleDirty: Bool { title != savedTitle }
    private var isLangDirty: Bool { lang != savedLang }

    /// A field's save was attempted but the site's title entry (`AnglesiteDisplayName` /
    /// `displayName`) is missing from `Info.plist` — shouldn't happen for a valid package, but
    /// guards against silently discarding an edit if it ever does.
    private enum SaveError: Error, LocalizedError {
        case titleEntryMissing

        var errorDescription: String? {
            switch self {
            case .titleEntryMissing:
                return "This site's Info.plist has no title entry to update."
            }
        }
    }

    private struct LoadResult: Sendable {
        let title: String
        let lang: String
        let domain: String?
        let stylesheets: [FileRef]
    }

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        let layout = SiteFileTree.layout(for: packageURL)
        let packageURL = packageURL
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.loadFromDisk(layout: layout, packageURL: packageURL)
            }.value
            title = result.title
            savedTitle = result.title
            lang = result.lang
            savedLang = result.lang
            domain = result.domain
            stylesheets = result.stylesheets
        } catch {
            loadError = error.localizedDescription
        }
    }

    private nonisolated static func loadFromDisk(layout: SiteFileTree.Layout, packageURL: URL) throws -> LoadResult {
        var title = ""
        if let infoPlistURL = layout.infoPlist {
            let loaded = try PlistDocumentIO.load(infoPlistURL)
            if let entry = loaded.entries.first(where: PlistEditorModel.isWebsiteTitleEntry),
               case .string(let value) = entry.value {
                title = value
            }
        }
        let configURL = layout.sourceDir.appendingPathComponent(".site-config")
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let lang = SiteLanguageAsset.parseSettings(from: config).lang
        let host = WebsiteAnalyticsAsset.bestHost(from: config, fallback: "")
        let domain = host.isEmpty ? nil : host
        let stylesheets = SiteFileTree.scan(siteRoot: packageURL)[.styles] ?? []
        return LoadResult(title: title, lang: lang, domain: domain, stylesheets: stylesheets)
    }

    @discardableResult
    func saveTitle() async -> Bool {
        guard isTitleDirty else { return true }
        guard !isSavingTitle else { return false }
        isSavingTitle = true
        saveError = nil
        defer { isSavingTitle = false }
        guard let infoPlistURL = SiteFileTree.layout(for: packageURL).infoPlist else {
            saveError = String(localized: "This site's Info.plist couldn't be found.")
            return false
        }
        let newTitle = title
        do {
            try await Task.detached(priority: .userInitiated) {
                var loaded = try PlistDocumentIO.load(infoPlistURL).entries
                guard let index = loaded.firstIndex(where: PlistEditorModel.isWebsiteTitleEntry) else {
                    throw SaveError.titleEntryMissing
                }
                loaded[index].value = .string(newTitle)
                try PlistDocumentIO.save(loaded, to: infoPlistURL)
            }.value
            savedTitle = newTitle
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Flushes every dirty field. Used by `SiteWindowModel.close(...)`/`handleSiteChanged()` as a
    /// last-writer-wins teardown save — the website inspector's mirror of `InspectorEditorModel
    /// .save()`, which the selection inspector's teardown already calls unconditionally and relies
    /// on to no-op when clean. `saveTitle()`/`saveLang()` each guard on their own dirty flag the
    /// same way, so calling both unconditionally here is safe to call even when nothing changed.
    @discardableResult
    func saveAll() async -> Bool {
        let titleSaved = await saveTitle()
        let langSaved = await saveLang()
        return titleSaved && langSaved
    }

    @discardableResult
    func saveLang() async -> Bool {
        guard isLangDirty else { return true }
        guard !isSavingLang else { return false }
        isSavingLang = true
        saveError = nil
        defer { isSavingLang = false }
        let sourceDir = SiteFileTree.layout(for: packageURL).sourceDir
        let settings = SiteLanguageAsset.Settings(lang: lang)
        do {
            try await Task.detached(priority: .userInitiated) {
                try SiteLanguageAsset.install(settings, siteDirectory: sourceDir)
            }.value
            lang = settings.lang
            savedLang = settings.lang
            return true
        } catch {
            saveError = String(localized: "Couldn't save website language: \(error.localizedDescription)")
            return false
        }
    }
}
