// Sources/AnglesiteApp/PageInspectorView.swift
import SwiftUI
import AnglesiteCore

/// Right-hand inspector content for the selected page. Renders the typed descriptor form or the
/// plain title/description form, wrapped in shared chrome (header + dirty/Save, off-main load,
/// external-change conflict alert; ⌘S arrives via File ▸ Save, see SaveCommands). Phase 1 has a
/// single "Page" section; a tab picker for
/// selection-level editing comes in Phase 3.
struct PageInspectorView: View {
    let context: InspectorContext
    /// Dev-server origin, threaded from `SiteWindow`/`SiteInspectorView`; nil until the preview
    /// server is up. Combined with `context.route` (via `PreviewNavigation.targetURL`) to give
    /// the "Shared as" section this page's live-preview URL to fetch a share card for (#2005).
    var previewBaseURL: URL?

    private var pageURL: URL? {
        previewBaseURL.map { PreviewNavigation.targetURL(base: $0, route: context.route) }
    }

    var body: some View {
        // `.id(context.id)` (the selected file's identity, from `InspectorContext.id`) forces
        // SwiftUI to treat a selection change as a brand-new view identity rather than an update
        // to the existing one — otherwise every `@State` in the form subtree (title/description
        // fields, `LanguagePicker`'s freeform-edit flag, …) survives the switch and can leak from
        // one file's editor into another's (e.g. "Other…" chosen with nothing typed on page A
        // still showing once the selection moves to page B, misrepresenting page B's actual
        // inheriting `lang`).
        Group {
            switch context {
            case .typed(let model):
                InspectorChrome(model: model) { TypedEntryForm(model: model, pageURL: pageURL) }
            case .page(let model):
                InspectorChrome(model: model) { PageMetadataForm(model: model, pageURL: pageURL) }
            case .generic(let model):
                InspectorChrome(model: model) { GenericPageInfoForm(model: model, pageURL: pageURL) }
            }
        }
        .id(context.id)
    }
}

/// Identity + the two shared search/crawling toggles for a page with no other editable metadata
/// (e.g. a plain `.astro` page) — see `GenericPageInspectorModel` (#1100, #1093).
private struct GenericPageInfoForm: View {
    @Bindable var model: GenericPageInspectorModel
    var pageURL: URL?

    var body: some View {
        Form {
            LabeledContent("Route", value: model.route)
            RobotsSettingsSection(route: model.route, noindex: model.noindexBinding(), disallowCrawl: model.disallowCrawlBinding())
            SharePreviewSection(pageURL: pageURL)
            Section {
                Text("Title, description, and body can't be edited for this page type yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The form for a plain (non-typed) frontmatter page: title, description, and the two shared
/// search/crawling toggles.
private struct PageMetadataForm: View {
    @Bindable var model: PageMetadataModel
    var pageURL: URL?

    var body: some View {
        Form {
            TextField("Title", text: model.titleBinding())
            VStack(alignment: .leading) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextField("", text: model.descriptionBinding(), axis: .vertical).lineLimit(2...6)
                    .accessibilityLabel("Description")
            }
            LanguageSettingsSection(tag: model.langBinding(), siteDefaultTag: model.siteDefaultLangTag)
            RobotsSettingsSection(route: model.route, noindex: model.noindexBinding(), disallowCrawl: model.disallowCrawlBinding())
            SharePreviewSection(pageURL: pageURL)
        }
        .formStyle(.grouped)
    }
}

/// Two independent per-page controls, shared by all three inspector form variants (#1093).
/// `noindex` and `disallowCrawl` are intentionally separate toggles, not one checkbox — see
/// docs/superpowers/specs/2026-07-30-robots-noindex-design.md for why combining them is a known
/// SEO anti-pattern (a crawler blocked by `disallowCrawl` never sees a `noindex` tag it can't fetch).
///
/// `route` exists for one reason: on the home page, "Block crawling entirely" emits `Disallow: /`,
/// which blocks the *whole site*, not one page. That consequence is invisible in an ordinary
/// checkbox, so it gets a confirmation phrased about what happens to the owner's site (AGENTS.md ▸
/// "The app advises; it does not delegate the decision").
struct RobotsSettingsSection: View {
    let route: String
    @Binding var noindex: Bool
    @Binding var disallowCrawl: Bool
    @State private var confirmingWholeSiteBlock = false

    /// Only the home page's route makes `Disallow:` site-wide; every other route disallows itself.
    private var blocksWholeSite: Bool { route == "/" }

    /// Intercepts only the off → on transition on the home page. Until the alert is confirmed the
    /// getter still reports the unchanged value, so the toggle snaps back to off on cancel.
    private var disallowCrawlProxy: Binding<Bool> {
        Binding(
            get: { disallowCrawl },
            set: { wants in
                if wants, blocksWholeSite {
                    confirmingWholeSiteBlock = true
                } else {
                    disallowCrawl = wants
                }
            }
        )
    }

    var body: some View {
        Section("Search & Crawling") {
            Toggle("Hide from search results", isOn: $noindex)
            Toggle("Block crawling entirely", isOn: disallowCrawlProxy)
                .help("Stronger than \"Hide from search results\" — well-behaved crawlers won't fetch this page at all, so a noindex tag on it would never be seen.")
        }
        .alert("Block crawling entirely for your whole site?", isPresented: $confirmingWholeSiteBlock) {
            Button("Cancel", role: .cancel) { }
            // Return-key default (#1736) — see the revert alert in `SiteWindow` for why the
            // default sits on the action rather than on Cancel. Reversible: the toggle above
            // turns it straight back off.
            Button("Block Crawling", role: .destructive) { disallowCrawl = true }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This is your home page — search engines won't be able to crawl any page reachable only through it.")
        }
    }
}

/// "Shared as" — a preview of what a link to this page would look like pasted into Mastodon,
/// Bluesky, Slack, iMessage, or LinkedIn (#2005). Shared by all three inspector form variants,
/// like `RobotsSettingsSection` above. Read-only: it reflects the title/description fields a few
/// rows above it in the same inspector, not an editable surface of its own.
///
/// Three states, none of them an alert or a modal (spec default 5): fetching, fetched, and
/// unavailable — the last covers both "no dev-server URL yet" and "the fetch failed," collapsed
/// into one plain sentence about the owner's site rather than distinguishing causes the owner
/// can't act on differently.
struct SharePreviewSection: View {
    /// This page's live-preview URL, or nil when the dev server isn't ready yet — in which case
    /// this section renders the unavailable state and issues no network request.
    let pageURL: URL?
    var fetchMetadata: @Sendable (URL) async throws -> LinkMetadata = { try await LinkMetadataFetcher().fetch(url: $0) }

    @State private var card: SharePreviewCard?
    // Seeded from `pageURL` at init, not `false`, so a page with a known URL renders the loading
    // state on its very first frame instead of a one-frame flash of "unavailable" before `.task`
    // below gets to flip it (code review finding).
    @State private var isFetching: Bool

    init(pageURL: URL?, fetchMetadata: @escaping @Sendable (URL) async throws -> LinkMetadata = { try await LinkMetadataFetcher().fetch(url: $0) }) {
        self.pageURL = pageURL
        self.fetchMetadata = fetchMetadata
        _isFetching = State(initialValue: pageURL != nil)
    }

    var body: some View {
        Section("Shared as") {
            content
        }
        // Refetches whenever the selection's page identity changes (including to/from nil) —
        // not on every keystroke in the title/description fields above (spec default 6).
        .task(id: pageURL) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isFetching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading preview…").foregroundStyle(.secondary)
            }
        } else if let card {
            SharePreviewCardBody(card: card)
        } else {
            Text("Anglesite can't preview this page's share card until the site preview is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        // Clears synchronously, before the first suspension point, so a selection change never
        // leaves the previous page's card showing while the new one loads.
        card = nil
        guard let pageURL else {
            isFetching = false
            return
        }
        isFetching = true
        defer { if !Task.isCancelled { isFetching = false } }
        do {
            let metadata = try await fetchMetadata(pageURL)
            guard !Task.isCancelled else { return }
            card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        } catch {
            // Folded into the same unavailable sentence as "no dev-server URL" — see the type doc.
            guard !Task.isCancelled else { return }
        }
    }
}

/// The card body itself: image (when present), title, description, and domain — each field
/// individually accessible to VoiceOver as text, with the image marked decorative since the text
/// fields already carry everything the image would (spec default 5's VoiceOver criterion).
private struct SharePreviewCardBody: View {
    let card: SharePreviewCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imageURL = card.imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(1.91, contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.1).aspectRatio(1.91, contentMode: .fit)
                }
                .frame(maxHeight: 140)
                .clipped()
                .accessibilityHidden(true)
            }
            Text(card.title ?? "No title")
                .font(.headline)
                .foregroundStyle(card.title == nil ? .secondary : .primary)
            Text(card.description ?? "No description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(card.domain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Shared inspector chrome around any `InspectorEditorModel`. Generic over the concrete model so the
/// form bodies keep their `@Bindable` two-way bindings.
private struct InspectorChrome<M: InspectorEditorModel & Observable, Form: View>: View {
    @Bindable var model: M
    @ViewBuilder var form: () -> Form
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError = model.loadError {
                    ContentUnavailableView {
                        Label("Can't open \(model.file.name)", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.file.url]) }
                    }
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    form()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.file.id) { await model.load() }
        .onChange(of: controlActiveState) { _, new in
            if new == .key { Task { await model.checkExternalChange() } }
        }
        // ⌘S is File ▸ Save (SaveCommands), which saves via SiteWindowModel.saveAllEdits() — no
        // per-view hidden shortcut button (it double-registered ⌘S alongside the editor's, #509).
        .alert("\(model.file.name) changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { model.keepMyChanges() }
            Button("Reload from Disk") { Task { await model.reloadFromDisk() } }
        } message: {
            Text("Another tool edited this file while you had unsaved changes.")
        }
    }

    private var header: some View {
        HStack {
            Label(model.file.name, systemImage: "doc.text").font(.headline)
            if model.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
            }
            Spacer()
            Button("Save") { Task { await model.save() } }.disabled(!model.isDirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflictDiskContents != nil }, set: { _ in })
    }
}
