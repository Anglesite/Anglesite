import SwiftUI
import AppKit
import WebKit
import AnglesiteCore

/// Drives the Effects gallery sheet (Website ▸ Effects…, formerly Animations, #1007/#768):
/// resolves the bundled template, decodes its curated `integrations/effects.json` catalog (legacy
/// `@astroanimate/core` micro-animations plus the newer hand-authored, placeable visual effects),
/// and tracks the selected entry. Catalog load failures (missing/unbundled template, malformed
/// manifest) surface as a plain error view — never a crash — since this is a browse-only surface
/// with no write path of its own; placement (see `EffectPlacementController`) is the one exception.
@MainActor
@Observable
final class EffectsGalleryModel {
    private(set) var catalog: EffectCatalog?
    private(set) var templateDirectory: URL?
    private(set) var loadError: String?
    var selectedComponent: String?

    var selectedEntry: EffectCatalogEntry? {
        guard let selectedComponent, let catalog else { return nil }
        return catalog.entries.first { $0.component == selectedComponent }
    }

    func load() {
        guard catalog == nil, loadError == nil else { return }
        let resolution = TemplateRuntime.resolve()
        guard let templateDirectory = resolution.url else {
            loadError = String(localized: "The website template isn't available (\(resolution.description)).")
            return
        }
        do {
            let catalog = try EffectCatalog.load(templateDirectory: templateDirectory)
            self.templateDirectory = templateDirectory
            self.catalog = catalog
            selectedComponent = catalog.entries.first?.component
        } catch {
            loadError = String(localized: "Couldn't load the effects catalog: \(error.localizedDescription)")
        }
    }

    func demoURL(for entry: EffectCatalogEntry) -> URL? {
        guard let templateDirectory else { return nil }
        return EffectCatalog.demoURL(templateDirectory: templateDirectory, component: entry.component)
    }
}

/// The Effects gallery sheet (Website ▸ Effects…, #768): browse the site template's curated,
/// CSP-safe effects catalog, preview each one's prerendered demo, copy its ready-to-paste
/// snippet, or — for entries with a `placement` — apply it directly to the page via
/// `EffectPlacementController`'s click-to-place flow. Sidebar groups entries by `EffectCategory`
/// under two headings (Micro-interactions / Visual effects); detail shows the owner description,
/// key-props table, a live demo `WKWebView`, Copy Snippet, and (when placeable) Apply to Page.
///
/// `controller`, `enterOverlayMode`, and `exitOverlayMode` are injected by the caller (Task 12:
/// `SiteWindow`/`SiteWindowModel`, which own the live preview's `WKWebView` and construct the
/// per-window `EffectPlacementController`) — this view has no WKWebView dependency of its own.
///
/// Once a placement starts, this sheet is out of the picture: it dismisses itself and the
/// placement HUD (``EffectPlacementHUD``, rendered on the site window) takes over. A sheet is
/// window-modal, so leaving it up would block clicks to the live preview the owner is being asked
/// to click (#768 final review, Finding 4).
struct EffectsGalleryView: View {
    @State private var model = EffectsGalleryModel()
    let controller: EffectPlacementController
    let enterOverlayMode: () -> Void
    let exitOverlayMode: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Set by ``startPlacement(for:)`` immediately before dismissing this sheet, so `onDisappear`
    /// can tell "the owner closed the gallery" from "the gallery handed off to the placement HUD".
    /// Without it, the hand-off's own dismissal would cancel the pick it just started.
    @State private var didHandOffToPlacement = false

    var body: some View {
        NavigationStack {
            galleryContent
                .navigationTitle("Effects")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { model.load() }
        // Any dismissal that isn't a placement hand-off cancels an in-progress pick (#768 final
        // review, Finding 2). `.onExitCommand` alone covered Esc but not Done — or a click on the
        // dimmed parent, or a programmatic dismiss — each of which used to leave the controller
        // `.picking` and the overlay's click-capture listener live, so the owner's next unrelated
        // click on the preview was silently swallowed and applied as an insert. `cancel()` is a
        // no-op when nothing is in progress, so the non-placement case costs nothing.
        .onDisappear {
            guard !didHandOffToPlacement else { return }
            controller.cancel()
        }
    }

    /// Starts a pick and gets out of the way: the gallery is a window-modal sheet, so it has to be
    /// dismissed before the owner can click the live preview underneath it at all (#768 final
    /// review, Finding 4). From here on the placement HUD on the site window
    /// (``EffectPlacementHUD``, presented by `SiteWindow`) owns the interaction — including Cancel
    /// and Esc — so cancelling never means reopening this sheet.
    private func startPlacement(for entry: EffectCatalogEntry) {
        didHandOffToPlacement = true
        controller.startPlacement(
            for: entry, enterOverlayMode: enterOverlayMode, exitOverlayMode: exitOverlayMode)
        dismiss()
    }

    @ViewBuilder private var galleryContent: some View {
        if let loadError = model.loadError {
            ContentUnavailableView(
                "Effects Unavailable",
                systemImage: "sparkles.slash",
                description: Text(loadError))
        } else if let catalog = model.catalog {
            NavigationSplitView {
                sidebar(catalog)
            } detail: {
                if let entry = model.selectedEntry {
                    EffectDetailView(
                        entry: entry,
                        demoURL: model.demoURL(for: entry),
                        controller: controller,
                        startPlacement: { startPlacement(for: $0) })
                } else {
                    ContentUnavailableView(
                        "No Component Selected",
                        systemImage: "wand.and.stars")
                }
            }
        } else {
            ProgressView("Loading effects…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Sidebar list, grouped under two contiguous headings. `EffectCategory` cases are ordered by
    /// group in `Self.microInteractionCategories`/`Self.visualEffectCategories` rather than
    /// nesting `Section` inside `Section`: a `List` on macOS is not guaranteed to render a
    /// two-level Section hierarchy with both headers visible (and this can only be confirmed by
    /// eye in a running app, which isn't available while authoring this change) — a flat `Section`
    /// per category plus a plain `Text` group-header row above each group's first category is the
    /// construct known to render correctly in a macOS sidebar `List`.
    private func sidebar(_ catalog: EffectCatalog) -> some View {
        List(selection: $model.selectedComponent) {
            sidebarGroup(catalog, title: "Micro-interactions", categories: Self.microInteractionCategories)
            sidebarGroup(catalog, title: "Visual effects", categories: Self.visualEffectCategories)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private static let microInteractionCategories: [EffectCategory] = [.text, .cards, .buttons, .backgrounds, .navigation]
    private static let visualEffectCategories: [EffectCategory] = [.canvasBackground, .cursorReactive, .scrollDriven, .generativeArt]

    @ViewBuilder
    private func sidebarGroup(_ catalog: EffectCatalog, title: String, categories: [EffectCategory]) -> some View {
        let nonEmptyCategories = categories.filter { !catalog.entries(in: $0).isEmpty }
        if !nonEmptyCategories.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(nonEmptyCategories, id: \.self) { category in
                Section(category.displayName) {
                    ForEach(catalog.entries(in: category)) { entry in
                        Text(entry.title).tag(entry.component)
                    }
                }
            }
        }
    }
}

extension EffectCategory {
    /// Sidebar/section title.
    var displayName: String {
        switch self {
        case .text: "Text"
        case .cards: "Cards"
        case .buttons: "Buttons"
        case .backgrounds: "Backgrounds"
        case .navigation: "Navigation"
        case .canvasBackground: "Canvas Backgrounds"
        case .cursorReactive: "Cursor-Reactive"
        case .scrollDriven: "Scroll-Driven"
        case .generativeArt: "Generative Art"
        }
    }
}

/// Detail pane for one catalog entry: description, key-props table, live demo, Copy Snippet, and
/// — when `entry.placement` is non-nil — Apply to Page, which hands off to `controller`'s
/// click-to-place flow.
private struct EffectDetailView: View {
    let entry: EffectCatalogEntry
    let demoURL: URL?
    @Bindable var controller: EffectPlacementController
    /// Hands the entry back to `EffectsGalleryView.startPlacement(for:)`, which arms the
    /// controller *and* dismisses the gallery so the live preview is clickable.
    let startPlacement: (EffectCatalogEntry) -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.title2.bold())
            Text(entry.ownerDescription).foregroundStyle(.secondary)

            if !entry.keyProps.isEmpty {
                keyPropsTable
            }

            if let demoURL {
                EffectDemoWebView(url: demoURL)
                    .frame(minHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.snippet, forType: .string)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy Snippet", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .onChange(of: entry.component) { _, _ in didCopy = false }

                if entry.placement != nil {
                    Button {
                        startPlacement(entry)
                    } label: {
                        Label("Apply to Page…", systemImage: "hand.tap")
                    }
                    .disabled(controller.state != .idle)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var keyPropsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key Props").font(.headline)
            ForEach(entry.keyProps.sorted(by: { $0.key < $1.key }), id: \.key) { key, description in
                HStack(alignment: .top, spacing: 6) {
                    Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    Text(description)
                }
            }
        }
    }
}

/// Loads a prerendered demo page (self-contained HTML with inline `<style>` only, no `<script>`
/// tags — enforced by the template's curation tests) via `loadFileURL`, scoped to the template
/// directory so the demo's sibling assets (if any) would also resolve.
private struct EffectDemoWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isInspectable = true
        loadIfNeeded(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadIfNeeded(webView)
    }

    private func loadIfNeeded(_ webView: WKWebView) {
        guard webView.url != url else { return }
        // Read access to the demo file's own directory covers the demo itself; sibling assets
        // (if a future demo needs any) would resolve the same way.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
