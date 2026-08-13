import SwiftUI
import AppKit
import AnglesiteCore

/// The New Site template chooser (#1071) — the iWork model: one question (which template),
/// then the site scaffolds as "Untitled" into the default location and opens in the preview.
/// Presented from SitesLauncherView; calls `onComplete(siteID)` when the site is scaffolded
/// and registered.
struct NewSiteWizard: View {
    @Bindable var model: NewSiteWizardModel
    let scaffolder: SiteScaffolder
    let templateURL: URL
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 480)
        // The scaffold pipeline isn't cancellable — block Esc/interactive dismissal once it starts.
        .interactiveDismissDisabled(model.step == .building)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .chooser:  chooserStep
        case .building: buildingStep
        }
    }

    private var chooserStep: some View {
        HStack(alignment: .top, spacing: 0) {
            categorySidebar
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a Template").font(.title2.bold())
                if model.filteredThemes.isEmpty {
                    emptyCategoryState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(model.filteredThemes) { theme in
                                ThemeChooserCard(
                                    theme: theme,
                                    templateURL: templateURL,
                                    isSelected: model.draft.themeID == theme.id,
                                    onSelect: { model.draft.themeID = theme.id },
                                    onCreate: {
                                        model.draft.themeID = theme.id
                                        create()
                                    }
                                )
                            }
                        }
                    }
                }
            }.padding(24)
        }
    }

    /// The six chooser categories (`NewSiteWizardModel.chooserCategories`), presented as a
    /// standard macOS sidebar `List` (matching `IntegrationWizard`'s picker convention) rather
    /// than hand-rolled buttons — `List(selection:)` gives arrow-key navigation, the system
    /// sidebar selection appearance, and VoiceOver container semantics for free, and makes each
    /// row's clickable area and visible highlight the same rect by construction.
    private var categorySidebar: some View {
        List(NewSiteWizardModel.chooserCategories, id: \.self, selection: categorySelection) { category in
            Label(category.label, systemImage: category.symbol)
        }
        .listStyle(.sidebar)
        .frame(width: 160)
    }

    /// Adapts `model.selectedCategory` (non-optional, always has a value) to the
    /// `Binding<SiteType?>` `List(selection:)` requires, routing every change through
    /// `model.selectCategory(_:)` so category switches keep applying the model's pre-selection
    /// rules. `List` only ever sets this to a row's value or `nil` (deselect); a `nil` write is
    /// ignored so the sidebar always shows a selected category, matching this chooser's
    /// always-one-category-active design.
    private var categorySelection: Binding<SiteType?> {
        Binding(
            get: { model.selectedCategory },
            set: { newValue in
                guard let newValue else { return }
                model.selectCategory(newValue)
            }
        )
    }

    /// Shown when a category has no matching themes yet (every non-Blank category, until
    /// #1179 slice 4 ports real themes into it) — an empty grid with no explanation would
    /// read as a bug.
    private var emptyCategoryState: some View {
        VStack {
            Spacer()
            Text("No themes in this category yet").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your website\u{2026}").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
                    // The visible label leads with an emoji status glyph; give VoiceOver clean text.
                    .accessibilityLabel(accessibilityLabel(for: s))
            }
            if case .failed(_, let msg) = model.fatal {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Build failed")
                    .accessibilityValue(msg)
            }
            if model.completedSiteID != nil && model.hasWarnings {
                Text("Your website was created, but something above needs attention before it can preview. You can open it anyway and fix it from the website window.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityLabel("Your website was created with warnings. You can open it anyway and fix it from the website window.")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "\u{2705} Created the website file"
        case .copyingTemplate: return "\u{2705} Copied the template"
        case .applyingTheme: return "\u{2705} Applied your theme"
        case .writingContent: return "\u{2705} Prepared the starter content"
        case .installing: return "\u{23F3} Installing\u{2026}"
        case .registering: return "\u{2705} Registering"
        case .warning(_, let m): return "\u{26A0}\u{FE0F} \(m)"
        case .failed(_, let m): return "\u{274C} \(m)"
        case .done: return "\u{2705} Done"
        }
    }

    /// Emoji-free version of `label(for:)` for VoiceOver, which would otherwise read the status
    /// glyph as "check mark", "hourglass", etc. before the actual message.
    private func accessibilityLabel(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder:    return "Created the website file"
        case .copyingTemplate:   return "Copied the template"
        case .applyingTheme:     return "Applied your theme"
        case .writingContent:    return "Prepared the starter content"
        case .installing:        return "Installing…"
        case .registering:       return "Registering"
        case .warning(_, let m): return "Warning: \(m)"
        case .failed(_, let m):  return "Failed: \(m)"
        case .done:              return "Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            // No Cancel once building starts: the scaffold pipeline isn't cancellable and
            // always reaches .done or .failed (failure shows Close below), so cancelling
            // mid-build would leak the in-flight work and the MAS security scope.
            if model.step == .chooser {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
            } else if let id = model.completedSiteID, model.hasWarnings {
                Button("Open Website Anyway") { onComplete(id) }.keyboardShortcut(.defaultAction)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func create() {
        guard model.canCreate else { return }
        // Auto-open only on a clean build; with warnings, stay put so the owner sees them (#229).
        Task {
            _ = await model.build(using: scaffolder)
            if model.didCompleteCleanly, let id = model.completedSiteID { onComplete(id) }
        }
    }
}

/// One selectable template card in the chooser grid — owns its own hover state so each
/// `ForEach` item tracks the mouse independently rather than sharing one flag across the grid
/// (#677).
private struct ThemeChooserCard: View {
    let theme: Theme
    let templateURL: URL
    let isSelected: Bool
    let onSelect: () -> Void
    let onCreate: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !isSelected }

    var body: some View {
        Button(action: onSelect) {
            ThemePreviewCard(theme: theme, templateURL: templateURL, isSelected: isSelected, isHoverActive: isHoverActive)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Double-click = choose and create, the document-chooser convention.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onCreate))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name). \(theme.blurb)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

/// One template card: a miniature page mock (nav bar, hero block, text lines) drawn from the
/// theme's own palette, so each card previews a page rather than a bare swatch strip (#1071).
private struct ThemePreviewCard: View {
    let theme: Theme
    let templateURL: URL
    let isSelected: Bool
    let isHoverActive: Bool

    private var primary: Color { Color(hex: theme.cssVars["color-primary"] ?? "#333333") }
    private var accent: Color { Color(hex: theme.cssVars["color-accent"] ?? "#888888") }

    /// Loaded synchronously — pack thumbnails are small, committed, bundle-local PNGs (same
    /// assumption `WebsiteIconInstaller` makes for site icons), so there's no async/loading
    /// state to model.
    private var thumbnailImage: NSImage? {
        guard let thumbnail = theme.thumbnail else { return nil }
        return NSImage(contentsOf: templateURL.appendingPathComponent(thumbnail))
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if isHoverActive { return Color.accentColor.opacity(0.4) }
        return Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let thumbnailImage {
                    Image(nsImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                } else {
                    syntheticMock
                }
            }
            Text(theme.name).font(.subheadline.bold())
            Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHoverActive ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
    }

    /// The two-color miniature page mock for CSS-var themes (#1071) — unchanged from before
    /// thumbnails existed, just extracted so `body` can branch on `thumbnailImage`.
    private var syntheticMock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 34, height: 4)
                Spacer()
            }
            .padding(6)
            .background(primary)
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.85)).frame(height: 22)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.5)).frame(width: 70, height: 4)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.25)).frame(height: 3)
                .padding(.horizontal, 6)
            Capsule().fill(Color.primary.opacity(0.25)).frame(width: 90, height: 3)
                .padding(.horizontal, 6).padding(.bottom, 8)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityHidden(true)
    }
}

/// Minimal hex -> Color for theme cards (#rrggbb). Also used by ThemeApplyWizard — keep it
/// here (module-internal) when refactoring this file.
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self = Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
