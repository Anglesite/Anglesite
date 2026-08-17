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
            loadError = "The website template isn't available (\(resolution.description))."
            return
        }
        do {
            let catalog = try EffectCatalog.load(templateDirectory: templateDirectory)
            self.templateDirectory = templateDirectory
            self.catalog = catalog
            selectedComponent = catalog.entries.first?.component
        } catch {
            loadError = "Couldn't load the effects catalog: \(error.localizedDescription)"
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
struct EffectsGalleryView: View {
    @State private var model = EffectsGalleryModel()
    let controller: EffectPlacementController
    let enterOverlayMode: () -> Void
    let exitOverlayMode: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Controls the transient success/failure banner: set true when `controller.state` becomes
    /// `.succeeded`/`.failed`, then cleared after a short delay so the banner fades away without
    /// requiring `EffectPlacementController` itself to transition back out of those terminal
    /// states (its `cancel()` only rewinds `.picking`, by design — see `EffectPlacementController`).
    @State private var showTransientBanner = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Effects")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { model.load() }
        .onExitCommand { controller.cancel() }
        .onChange(of: controller.state) { _, newState in
            switch newState {
            case .succeeded, .failed:
                showTransientBanner = true
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    showTransientBanner = false
                }
            default:
                showTransientBanner = false
            }
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            galleryContent
            placementHUD
        }
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
                        enterOverlayMode: enterOverlayMode,
                        exitOverlayMode: exitOverlayMode)
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

    /// Click-to-place HUD: the persistent "pick a spot" / "applying" states, plus a transient
    /// banner for the terminal `.succeeded`/`.failed` states (see `showTransientBanner`).
    @ViewBuilder private var placementHUD: some View {
        switch controller.state {
        case .picking:
            placementBanner(message: "Click where to place this effect", tint: .accentColor, showCancelButton: true)
        case .applying:
            placementBanner(message: "Applying…", tint: .accentColor, showCancelButton: false)
        case .succeeded where showTransientBanner:
            placementBanner(message: "Effect placed.", tint: .green, showCancelButton: false)
        case .failed(let message) where showTransientBanner:
            placementBanner(message: message, tint: .red, showCancelButton: false)
        default:
            EmptyView()
        }
    }

    private func placementBanner(message: String, tint: Color, showCancelButton: Bool) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(message)
                if showCancelButton {
                    Button("Cancel") { controller.cancel() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(tint, lineWidth: 1))
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(.default, value: showTransientBanner)
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
    let enterOverlayMode: () -> Void
    let exitOverlayMode: () -> Void
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
                        controller.startPlacement(
                            for: entry, enterOverlayMode: enterOverlayMode, exitOverlayMode: exitOverlayMode)
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
